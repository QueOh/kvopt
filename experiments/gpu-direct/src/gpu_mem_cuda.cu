/*   SPDX-License-Identifier: BSD-3-Clause
 *   Copyright (C) 2026 Samsung Electronics Co., Ltd.
 *
 * Real GPU backend: CUDA VMM allocation with DMA-BUF export
 * (CUDA >= 11.7, kernel >= 5.12, mlx5) + device-side pattern check.
 * Compile with nvcc on the GPU node only.
 */

extern "C" {
#include "gpu_mem.h"
}

#include <cstdio>
#include <cstring>
#include <unistd.h>
#include <cuda.h>
#include <cuda_runtime.h>

struct cuda_impl {
	CUmemGenericAllocationHandle handle;
	CUcontext ctx;
};

#define CU_TRY(call)							\
	do {								\
		CUresult _st = (call);					\
		if (_st != CUDA_SUCCESS) {				\
			const char *_es = NULL;				\
			cuGetErrorString(_st, &_es);			\
			fprintf(stderr, "gpu_mem: %s -> %s\n", #call,	\
				_es ? _es : "?");			\
			return -1;					\
		}							\
	} while (0)

extern "C" int
gpu_mem_alloc(int gpu_id, size_t size, struct gpu_buf *buf)
{
	CUdevice dev;
	cuda_impl *impl;
	int dmabuf_supported = 0;

	CU_TRY(cuInit(0));
	CU_TRY(cuDeviceGet(&dev, gpu_id));

	impl = new cuda_impl();
	CU_TRY(cuCtxCreate(&impl->ctx, 0, dev));

	CU_TRY(cuDeviceGetAttribute(&dmabuf_supported,
				    CU_DEVICE_ATTRIBUTE_DMA_BUF_SUPPORTED, dev));
	if (!dmabuf_supported) {
		fprintf(stderr, "gpu_mem: GPU %d lacks DMA-BUF export\n", gpu_id);
		return -1;
	}

	CUmemAllocationProp prop = {};
	prop.type = CU_MEM_ALLOCATION_TYPE_PINNED;
	prop.requestedHandleTypes = CU_MEM_HANDLE_TYPE_DMA_BUF_FD;
	prop.location.type = CU_MEM_LOCATION_TYPE_DEVICE;
	prop.location.id = gpu_id;

	size_t gran = 0;
	CU_TRY(cuMemGetAllocationGranularity(&gran, &prop,
					     CU_MEM_ALLOC_GRANULARITY_MINIMUM));
	size_t asize = (size + gran - 1) / gran * gran;

	CUdeviceptr dptr;
	CU_TRY(cuMemCreate(&impl->handle, asize, &prop, 0));
	CU_TRY(cuMemAddressReserve(&dptr, asize, gran, 0, 0));
	CU_TRY(cuMemMap(dptr, asize, 0, impl->handle, 0));

	CUmemAccessDesc access = {};
	access.location.type = CU_MEM_LOCATION_TYPE_DEVICE;
	access.location.id = gpu_id;
	access.flags = CU_MEM_ACCESS_FLAGS_PROT_READWRITE;
	CU_TRY(cuMemSetAccess(dptr, asize, &access, 1));

	int fd = -1;
	CU_TRY(cuMemExportToShareableHandle(&fd, impl->handle,
					    CU_MEM_HANDLE_TYPE_DMA_BUF_FD, 0));

	buf->dptr = (uint64_t)dptr;
	buf->size = asize;
	buf->dmabuf_fd = fd;
	buf->impl = impl;
	return 0;
}

extern "C" void
gpu_mem_free(struct gpu_buf *buf)
{
	cuda_impl *impl = (cuda_impl *)buf->impl;

	if (impl == NULL) {
		return;
	}
	if (buf->dmabuf_fd >= 0) {
		close(buf->dmabuf_fd);
	}
	cuMemUnmap((CUdeviceptr)buf->dptr, buf->size);
	cuMemAddressFree((CUdeviceptr)buf->dptr, buf->size);
	cuMemRelease(impl->handle);
	cuCtxDestroy(impl->ctx);
	delete impl;
	memset(buf, 0, sizeof(*buf));
}

extern "C" int
gpu_mem_poison(struct gpu_buf *buf, uint8_t byte)
{
	if (cudaMemset((void *)buf->dptr, byte, buf->size) != cudaSuccess) {
		return -1;
	}
	return cudaDeviceSynchronize() == cudaSuccess ? 0 : -1;
}

/* One thread per dword; compares against the deterministic pattern and
 * accumulates a digest. The payload never leaves the GPU.
 */
__global__ static void
check_pattern_kernel(const uint32_t *data, uint64_t first_lba,
		     uint32_t dwords_per_block, uint64_t total_dwords,
		     unsigned long long *mismatches,
		     unsigned long long *first_bad, /* dword idx, ~0 init */
		     unsigned long long *sum)
{
	uint64_t i = (uint64_t)blockIdx.x * blockDim.x + threadIdx.x;

	if (i >= total_dwords) {
		return;
	}

	uint64_t blk = first_lba + i / dwords_per_block;
	uint32_t j = (uint32_t)(i % dwords_per_block);
	uint32_t expected = (uint32_t)((blk << 12) | (j & 0xFFFu));
	uint32_t got = data[i];

	atomicAdd(sum, (unsigned long long)got);
	if (got != expected) {
		atomicAdd(mismatches, 1ULL);
		atomicMin(first_bad, (unsigned long long)i);
	}
}

extern "C" int
gpu_checksum_pattern(struct gpu_buf *buf, uint64_t first_lba,
		     uint32_t blocks, uint32_t block_size,
		     struct gpu_digest *digest)
{
	uint32_t dwords_per_block = block_size / 4;
	uint64_t total = (uint64_t)blocks * dwords_per_block;
	unsigned long long *dev_stats; /* [0]=mismatches [1]=first_bad [2]=sum */
	unsigned long long host_stats[3];

	if (cudaMalloc(&dev_stats, sizeof(host_stats)) != cudaSuccess) {
		return -1;
	}
	host_stats[0] = 0;
	host_stats[1] = ~0ULL;
	host_stats[2] = 0;
	cudaMemcpy(dev_stats, host_stats, sizeof(host_stats), cudaMemcpyHostToDevice);

	int tpb = 256;
	int grid = (int)((total + tpb - 1) / tpb);
	check_pattern_kernel<<<grid, tpb>>>((const uint32_t *)buf->dptr, first_lba,
					    dwords_per_block, total,
					    &dev_stats[0], &dev_stats[1], &dev_stats[2]);
	if (cudaDeviceSynchronize() != cudaSuccess) {
		cudaFree(dev_stats);
		return -1;
	}

	/* only these 24 bytes cross to the host */
	cudaMemcpy(host_stats, dev_stats, sizeof(host_stats), cudaMemcpyDeviceToHost);
	cudaFree(dev_stats);

	digest->mismatch_count = host_stats[0];
	digest->first_bad_offset = host_stats[0] == 0 ? -1 :
				   (int64_t)(host_stats[1] * 4);
	digest->sum = host_stats[2];
	return 0;
}

extern "C" const char *
gpu_mem_backend_name(void)
{
	return "cuda-vmm-dmabuf";
}
