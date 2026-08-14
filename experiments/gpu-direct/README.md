# Direct NVMe-oF → GPU HBM — verification kit

Implements `direct_nvmeof_gpu_verification_plan.md` (repo root). Goal:
prove JBOF → GPU HBM over NVMe-oF/RDMA + GPUDirect with **no
Object/Data Node and no host bounce buffer** in the payload path.

## Artifact map (plan §17 tasks → files)

| § | task | artifact | runs on |
|---|---|---|---|
| 1 | inventory | `stages/00_inventory.sh` | GPU node |
| 2 | RDMA→HBM bandwidth | `stages/01_rdma_gpu_bw.sh` | GPU node + RDMA peer |
| 3 | SPDK host-memory baseline | `stages/02_spdk_host_baseline.sh` | GPU node |
| 4 | GDS reference | `stages/03_gds_reference.sh` | GPU node |
| 4/5 | GDS direct proof + bounce counters | `stages/04_gds_direct_proof.sh` | GPU node |
| 5 | alignment matrix | `stages/05_alignment_matrix.sh` | GPU node |
| 6 | GPU RDMA registration | `src/gpu_rdma_memory_test.c` | GPU node |
| 7 | fixed-LBA reader | `spdk/app/spdk_fixed_lba_read/` (in the SPDK submodule) | anywhere |
| 8 | CUDA checksum | `src/gpu_mem_cuda.cu` (`gpu_checksum_pattern`) | GPU node |
| 9 | GPU memory-domain provider | `src/spdk_gpu_read.c` (`gpu_domain_translate`) | GPU node |
| 10 | host payload → GPU HBM | `src/spdk_gpu_read.c` (read_ext + domain) | GPU node |
| 11 | MR/domain logging | built into 8-10 (stderr) | — |
| 12 | no-fallback negative test | `spdk_gpu_read -X` | GPU node |
| 13/14 | size/QD matrices | `02_spdk_host_baseline.sh` sweeps + rerun `spdk_gpu_read -c/-L` | GPU node |
| 15 | 3-way compare | JSON outputs of stages 3, 2, 10 | — |

All programs emit the plan §18 JSON schema (one line on stdout).

## Build

```bash
# SPDK apps (any Linux host; the SPDK submodule must be built):
cd spdk && ./configure --with-rdma && make -j$(nproc)
#   -> build/bin/spdk_fixed_lba_read

# GPU-node programs:
cd experiments/gpu-direct/src
make gpu_rdma_memory_test          # CUDA + libibverbs
make spdk_gpu_read                 # CUDA + libibverbs + built SPDK (--with-rdma)

# compile-check of the SPDK-side code on a host WITHOUT CUDA
# (binary refuses at runtime — stub backend, no fallback):
make spdk_gpu_read_stub
```

## Milestone 1 (plan §19) — the one command that matters

```bash
# once: put the deterministic pattern on the known LBA range
build/bin/spdk_fixed_lba_read -r "$TRID" -n 1 -L 0 -c 256 -W -J

# the direct read: JBOF -> GPU HBM, checksum in-HBM, digest-only readback
experiments/gpu-direct/src/spdk_gpu_read -r "$TRID" -n 1 -L 0 -c 256 -J

# mandatory negative test (plan §15): poisoned registration MUST fail the I/O
experiments/gpu-direct/src/spdk_gpu_read -r "$TRID" -n 1 -L 0 -c 256 -X -J
```

## Pass gates (plan §20 — ALL must hold)

1. READ completes; `checksum_ok:true` from the **in-HBM** kernel.
2. `rdma_registration:true` (DMA-BUF MR on the transport PD; lkey/rkey
   logged) and `host_payload_buffer:false` (the app allocates none).
3. During the read: NIC RX ≈ GPU PCIe RX ≈ storage throughput; host
   DRAM ≈ baseline (stage-4 instrumentation, run alongside).
4. No `memcpy`/`cudaMemcpy` of payload (by construction: only the
   24-byte digest crosses; grep the sources).
5. `-X` negative test: I/O **fails** (`negative_test:true,io_failed:true`
   → PASS). A success here means a hidden fallback — hard FAIL.

## Mechanism notes

- GPU memory: CUDA VMM (`cuMemCreate` + `CU_MEM_HANDLE_TYPE_DMA_BUF_FD`)
  exported as DMA-BUF, registered with `ibv_reg_dmabuf_mr` — needs
  CUDA ≥ 11.7, kernel ≥ 5.12, mlx5. `00_inventory.sh` verifies the
  prerequisites (`gdscheck -p`, ACS, topology).
- SPDK side: an `SPDK_DMA_DEVICE_TYPE_RDMA` memory domain whose
  translation callback receives the transport QP
  (`dst_domain_ctx->rdma.ibv_qp`), lazily registers the DMA-BUF on
  **that QP's PD**, and returns the GPU VA + lkey/rkey. The NVMe RDMA
  transport then posts SGEs pointing straight at HBM.
- Status: SPDK-side code compiles and the fixed-LBA reader is
  functionally verified over TCP loopback (pattern write→read→verify).
  CUDA paths compile only on the GPU node — first run there is the
  real trial; failures land in the JSON/stderr and extend this README.
