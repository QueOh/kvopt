/*   SPDX-License-Identifier: BSD-3-Clause
 *   Copyright (C) 2026 Samsung Electronics Co., Ltd.
 *
 * Compile-check backend. Refuses everything at runtime — per the plan's
 * no-fallback rule it must NEVER hand out host memory disguised as GPU
 * memory. Exists so spdk_gpu_read's SPDK-side code (memory domain,
 * translation, read_ext wiring) can be compiled and link-checked on
 * hosts without CUDA.
 */

#include <errno.h>
#include <stdio.h>
#include <string.h>

#include "gpu_mem.h"

int
gpu_mem_alloc(int gpu_id, size_t size, struct gpu_buf *buf)
{
	(void)gpu_id;
	(void)size;
	memset(buf, 0, sizeof(*buf));
	fprintf(stderr, "gpu_mem: built without CUDA (stub backend) - "
		"refusing, no host-memory fallback\n");
	return -ENOTSUP;
}

void
gpu_mem_free(struct gpu_buf *buf)
{
	(void)buf;
}

int
gpu_mem_poison(struct gpu_buf *buf, uint8_t byte)
{
	(void)buf;
	(void)byte;
	return -ENOTSUP;
}

int
gpu_checksum_pattern(struct gpu_buf *buf, uint64_t first_lba, uint32_t blocks,
		     uint32_t block_size, struct gpu_digest *digest)
{
	(void)buf;
	(void)first_lba;
	(void)blocks;
	(void)block_size;
	(void)digest;
	return -ENOTSUP;
}

const char *
gpu_mem_backend_name(void)
{
	return "stub-no-cuda";
}
