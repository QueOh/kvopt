/*   SPDX-License-Identifier: BSD-3-Clause
 *   Copyright (C) 2026 Samsung Electronics Co., Ltd.
 *
 * GPU memory backend interface for the direct NVMe-oF -> GPU HBM PoC.
 * Two implementations:
 *   gpu_mem_cuda.cu - real: CUDA VMM allocation exported as DMA-BUF,
 *                     pattern checksum computed by a CUDA kernel.
 *   gpu_mem_stub.c  - compile-check only: every call fails -ENOTSUP.
 *                     (No-fallback rule: the stub never provides host
 *                     memory pretending to be GPU memory.)
 */

#ifndef KVOPT_GPU_MEM_H
#define KVOPT_GPU_MEM_H

#include <stddef.h>
#include <stdint.h>

struct gpu_buf {
	uint64_t	dptr;		/* GPU virtual address */
	size_t		size;		/* mapped size (granularity-rounded) */
	int		dmabuf_fd;	/* exported DMA-BUF fd */
	void		*impl;		/* backend private */
};

struct gpu_digest {
	uint64_t	mismatch_count;
	int64_t		first_bad_offset;	/* bytes; -1 if clean */
	uint64_t	sum;			/* sum of dwords, informational */
};

/* Allocate GPU memory suitable for DMA-BUF export. */
int gpu_mem_alloc(int gpu_id, size_t size, struct gpu_buf *buf);
void gpu_mem_free(struct gpu_buf *buf);

/* Fill the buffer with a poison value (device-side). */
int gpu_mem_poison(struct gpu_buf *buf, uint8_t byte);

/* Device-side verification against the deterministic pattern
 * (dword j of absolute block b == (b << 12) | j). Only the small
 * digest crosses to the host — never the payload.
 */
int gpu_checksum_pattern(struct gpu_buf *buf, uint64_t first_lba,
			 uint32_t blocks, uint32_t block_size,
			 struct gpu_digest *digest);

const char *gpu_mem_backend_name(void);

#endif /* KVOPT_GPU_MEM_H */
