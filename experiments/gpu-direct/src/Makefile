#  SPDX-License-Identifier: BSD-3-Clause
#  Copyright (C) 2026 Samsung Electronics Co., Ltd.
#
# Builds the GPU-direct PoC programs.
#
#   make gpu_rdma_memory_test   stage 8  (needs CUDA + libibverbs)
#   make spdk_gpu_read          stage 9-10 (needs CUDA + libibverbs + built SPDK)
#   make spdk_gpu_read_stub     SPDK-side compile check without CUDA
#                               (refuses at runtime; no fallback)
#
# SPDK_ROOT points at a built SPDK tree (default: the kvopt submodule).
# CUDA_HOME autodetected from nvcc if unset.

SPDK_ROOT ?= $(abspath $(CURDIR)/../../../spdk)
PKGCONF = PKG_CONFIG_PATH=$(SPDK_ROOT)/build/lib/pkgconfig pkg-config
SPDK_LIBS = spdk_nvme spdk_env_dpdk spdk_util spdk_log spdk_dma
# SPDK's bundled ISA-L archives (xor_gen etc. used by spdk_util)
ISAL_LIBS = $(wildcard $(SPDK_ROOT)/isa-l/.libs/libisal.a) \
	    $(wildcard $(SPDK_ROOT)/isa-l-crypto/.libs/libisal_crypto.a)

CUDA_HOME ?= $(shell dirname $$(dirname $$(command -v nvcc 2>/dev/null)) 2>/dev/null)

CFLAGS ?= -O2 -g -Wall -Wextra
RPATHS = -Wl,--disable-new-dtags -Wl,-rpath,$(SPDK_ROOT)/dpdk/build/lib -Wl,-rpath,$(SPDK_ROOT)/build/lib
NVCCFLAGS ?= -O2

.PHONY: all clean check-cuda

all:
	@echo "targets: gpu_rdma_memory_test spdk_gpu_read spdk_gpu_read_stub"

check-cuda:
	@test -n "$(CUDA_HOME)" -a -e "$(CUDA_HOME)/include/cuda.h" || \
		{ echo "CUDA not found (set CUDA_HOME)"; exit 1; }

gpu_rdma_memory_test: gpu_rdma_memory_test.c check-cuda
	$(CC) $(CFLAGS) -I$(CUDA_HOME)/include -o $@ $< \
		-L$(CUDA_HOME)/lib64 -lcuda -libverbs

gpu_mem_cuda.o: gpu_mem_cuda.cu gpu_mem.h check-cuda
	nvcc $(NVCCFLAGS) -c -o $@ $<

spdk_gpu_read: spdk_gpu_read.c gpu_mem_cuda.o gpu_mem.h
	$(CC) $(CFLAGS) -I$(CUDA_HOME)/include \
		$$($(PKGCONF) --cflags $(SPDK_LIBS)) \
		-o $@ spdk_gpu_read.c gpu_mem_cuda.o \
		-Wl,--whole-archive $$($(PKGCONF) --libs $(SPDK_LIBS)) -Wl,--no-whole-archive \
		$$($(PKGCONF) --libs spdk_syslibs) \
		-L$(CUDA_HOME)/lib64 -lcuda -lcudart $(ISAL_LIBS) $(RPATHS) -libverbs -lstdc++ -lm -lssl -lcrypto -luuid -lnuma -lfuse3 -ldl -lrt -pthread

spdk_gpu_read_stub: spdk_gpu_read.c gpu_mem_stub.c gpu_mem.h
	$(CC) $(CFLAGS) \
		$$($(PKGCONF) --cflags $(SPDK_LIBS)) \
		-o $@ spdk_gpu_read.c gpu_mem_stub.c \
		-Wl,--whole-archive $$($(PKGCONF) --libs $(SPDK_LIBS)) -Wl,--no-whole-archive \
		$$($(PKGCONF) --libs spdk_syslibs) \
		$(ISAL_LIBS) $(RPATHS) -libverbs -lm -lssl -lcrypto -luuid -lnuma -lfuse3 -ldl -lrt -pthread

clean:
	rm -f gpu_rdma_memory_test spdk_gpu_read spdk_gpu_read_stub gpu_mem_cuda.o
