/*   SPDX-License-Identifier: BSD-3-Clause
 *   Copyright (C) 2026 Samsung Electronics Co., Ltd.
 *
 * gpu_rdma_memory_test - verification plan stage 8.
 *
 * Proves ONLY the registration chain, independent of SPDK:
 *
 *   CUDA allocation -> DMA-BUF export -> ibv_reg_dmabuf_mr -> MR
 *   (address, lkey, rkey printed as JSON)
 *
 * Mechanism: CUDA VMM (cuMemCreate with the DMA-BUF-capable handle
 * type) + cuMemExportToShareableHandle(..., DMABUF_FD), then
 * ibv_reg_dmabuf_mr() on the chosen ibverbs device. This is the
 * modern replacement for nv_peer_mem and needs CUDA >= 11.7,
 * a >= 5.12-era kernel and an mlx5 device.
 *
 * Build (GPU node only): make gpu_rdma_memory_test  (needs nvcc/CUDA
 * driver API + libibverbs; see Makefile).
 *
 * No-fallback rule: every failure is fatal and reported; nothing falls
 * back to host memory.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <stdint.h>
#include <stdbool.h>

#include <infiniband/verbs.h>
#include <cuda.h>

#define CHECK_CU(call)							\
	do {								\
		CUresult _st = (call);					\
		if (_st != CUDA_SUCCESS) {				\
			const char *_es = NULL;				\
			cuGetErrorString(_st, &_es);			\
			fprintf(stderr, "FATAL %s:%d %s -> %s\n",	\
				__FILE__, __LINE__, #call,		\
				_es ? _es : "?");			\
			exit(1);					\
		}							\
	} while (0)

int
main(int argc, char **argv)
{
	size_t size = 1 << 20; /* 1 MiB, matching milestone 1 */
	const char *dev_name = NULL;
	int gpu_id = 0;
	int c;

	while ((c = getopt(argc, argv, "d:g:s:h")) != -1) {
		switch (c) {
		case 'd':
			dev_name = optarg;
			break;
		case 'g':
			gpu_id = atoi(optarg);
			break;
		case 's':
			size = strtoull(optarg, NULL, 0);
			break;
		default:
			fprintf(stderr,
				"usage: %s [-d ibdev] [-g gpu] [-s bytes]\n",
				argv[0]);
			return 1;
		}
	}

	/* ---- CUDA: VMM allocation with DMA-BUF export capability ---- */
	CUdevice dev;
	CUcontext ctx;
	CHECK_CU(cuInit(0));
	CHECK_CU(cuDeviceGet(&dev, gpu_id));
	CHECK_CU(cuCtxCreate(&ctx, 0, dev));

	int dmabuf_supported = 0;
	CHECK_CU(cuDeviceGetAttribute(&dmabuf_supported,
				      CU_DEVICE_ATTRIBUTE_DMA_BUF_SUPPORTED, dev));
	if (!dmabuf_supported) {
		fprintf(stderr, "FATAL: GPU %d does not support DMA-BUF export\n", gpu_id);
		return 1;
	}

	CUmemAllocationProp prop = {
		.type = CU_MEM_ALLOCATION_TYPE_PINNED,
		.requestedHandleTypes = CU_MEM_HANDLE_TYPE_DMA_BUF_FD,
		.location = { .type = CU_MEM_LOCATION_TYPE_DEVICE, .id = gpu_id },
	};
	size_t gran = 0;
	CHECK_CU(cuMemGetAllocationGranularity(&gran, &prop,
					       CU_MEM_ALLOC_GRANULARITY_MINIMUM));
	size_t asize = (size + gran - 1) / gran * gran;

	CUmemGenericAllocationHandle handle;
	CUdeviceptr dptr;
	CHECK_CU(cuMemCreate(&handle, asize, &prop, 0));
	CHECK_CU(cuMemAddressReserve(&dptr, asize, gran, 0, 0));
	CHECK_CU(cuMemMap(dptr, asize, 0, handle, 0));
	CUmemAccessDesc access = {
		.location = { .type = CU_MEM_LOCATION_TYPE_DEVICE, .id = gpu_id },
		.flags = CU_MEM_ACCESS_FLAGS_PROT_READWRITE,
	};
	CHECK_CU(cuMemSetAccess(dptr, asize, &access, 1));

	int dmabuf_fd = -1;
	CHECK_CU(cuMemExportToShareableHandle(&dmabuf_fd, handle,
					      CU_MEM_HANDLE_TYPE_DMA_BUF_FD, 0));

	/* ---- ibverbs: register the DMA-BUF as an MR ---- */
	int ndev = 0;
	struct ibv_device **devs = ibv_get_device_list(&ndev);
	if (devs == NULL || ndev == 0) {
		fprintf(stderr, "FATAL: no RDMA devices\n");
		return 1;
	}
	struct ibv_device *ibdev = devs[0];
	for (int i = 0; dev_name != NULL && i < ndev; i++) {
		if (strcmp(ibv_get_device_name(devs[i]), dev_name) == 0) {
			ibdev = devs[i];
		}
	}

	struct ibv_context *ibctx = ibv_open_device(ibdev);
	if (ibctx == NULL) {
		fprintf(stderr, "FATAL: ibv_open_device(%s): %s\n",
			ibv_get_device_name(ibdev), strerror(errno));
		return 1;
	}
	struct ibv_pd *pd = ibv_alloc_pd(ibctx);
	if (pd == NULL) {
		fprintf(stderr, "FATAL: ibv_alloc_pd: %s\n", strerror(errno));
		return 1;
	}

	struct ibv_mr *mr = ibv_reg_dmabuf_mr(pd, 0 /* offset */, asize,
					      (uint64_t)dptr, dmabuf_fd,
					      IBV_ACCESS_LOCAL_WRITE |
					      IBV_ACCESS_REMOTE_WRITE |
					      IBV_ACCESS_REMOTE_READ);
	if (mr == NULL) {
		fprintf(stderr, "FATAL: ibv_reg_dmabuf_mr: %s "
			"(kernel/driver lacks GPU DMA-BUF import?)\n",
			strerror(errno));
		return 1;
	}

	printf("{\"test\":\"gpu_rdma_memory_test\",\"gpu\":%d,"
	       "\"ibdev\":\"%s\",\"bytes\":%zu,"
	       "\"gpu_addr\":\"0x%llx\",\"dmabuf_fd\":%d,"
	       "\"lkey\":\"0x%x\",\"rkey\":\"0x%x\","
	       "\"rdma_registration\":true,\"host_payload_buffer\":false,"
	       "\"result\":\"PASS\"}\n",
	       gpu_id, ibv_get_device_name(ibdev), asize,
	       (unsigned long long)dptr, dmabuf_fd, mr->lkey, mr->rkey);

	ibv_dereg_mr(mr);
	ibv_dealloc_pd(pd);
	ibv_close_device(ibctx);
	ibv_free_device_list(devs);
	close(dmabuf_fd);
	cuMemUnmap(dptr, asize);
	cuMemAddressFree(dptr, asize);
	cuMemRelease(handle);
	cuCtxDestroy(ctx);
	return 0;
}
