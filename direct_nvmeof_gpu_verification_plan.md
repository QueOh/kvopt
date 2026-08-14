# Verification Plan for Direct NVMe-oF to GPU HBM

**Date:** 2026-08-14  
**Goal:** Verify that data can move directly from an NVMe-oF JBOF into GPU HBM over RDMA, without an Object Storage/Data Node and without a GPU-host-DRAM payload bounce buffer.

## 1. Target Architecture

```text
NVMe SSD
   |
   v
JBOF NVMe-oF Target
   |
   | NVMe-oF / RDMA
   v
GPU-node RDMA NIC
   |
   | GPUDirect RDMA
   v
GPU HBM
```

The experiment must prove that neither an Object/Data Node nor a GPU-node host-memory bounce buffer participates in the payload path.

## 2. Verification Strategy

Validate the system in layers:

```text
Stage 0: Hardware / topology validation
        |
        v
Stage 1: RDMA -> GPU HBM
        |
        v
Stage 2: JBOF -> SPDK host memory
        |
        v
Stage 3: JBOF -> GPU HBM using GDS
        |
        v
Stage 4: Verify no GDS bounce buffer
        |
        v
Stage 5: Alignment experiments
        |
        v
Stage 6: Minimal SPDK fixed-LBA reader
        |
        v
Stage 7: Deterministic data validation
        |
        v
Stage 8: GPU RDMA registration
        |
        v
Stage 9: SPDK GPU memory-domain integration
        |
        v
Stage 10: Direct NVMe READ -> GPU HBM
```

## 3. Stage 0 — Hardware and Topology Inventory

Create `00_inventory.sh` and collect:

```bash
uname -a
cat /etc/redhat-release

nvidia-smi
nvidia-smi -q
nvidia-smi topo -m

lspci -tv
lspci -nn | grep -Ei 'nvidia|mellanox|network|ethernet|nvme'

ibv_devices
ibv_devinfo
rdma link

nvme list
nvme list-subsys

/usr/local/cuda/gds/tools/gdscheck -p
```

Also inspect `lspci -vvv` for GPU/NIC PCIe placement, NUMA locality, ACS behavior, link width, and PCIe generation.

### Pass criteria

- CUDA recognizes the GPU.
- RDMA recognizes the NIC.
- JBOF is reachable.
- NVMe-oF connection can be established.
- GPU/NIC topology supports GPUDirect RDMA.
- No obvious ACS/P2P restriction blocks peer DMA.

## 4. Stage 1 — Verify RDMA Directly into GPU HBM

Before involving NVMe, prove:

```text
Remote RDMA peer
      |
      | RDMA WRITE
      v
GPU-node ConnectX
      |
      | GPUDirect RDMA
      v
GPU HBM
```

Use a GPU-capable RDMA benchmark such as `ib_write_bw` with CUDA-backed or DMA-BUF-backed memory if supported by the installed stack.

Initialize the GPU buffer with a known pattern, overwrite it using RDMA, then launch a CUDA checksum kernel.

Do not validate by copying the entire payload to the CPU.

### Pass criteria

- RDMA WRITE succeeds.
- CUDA kernel sees the new data.
- Checksum matches.
- No application-level host payload buffer exists.

## 5. Stage 2 — Verify SPDK NVMe-oF with Host Memory

Test:

```text
NVMe SSD
   |
   v
JBOF NVMe-oF Target
   |
   | RDMA
   v
SPDK NVMe-oF Initiator
   |
   v
Host DMA Memory
```

Use SPDK's NVMe performance example.

Example:

```bash
./build/examples/perf     -q 32     -o 4096     -w read     -r 'trtype:RDMA adrfam:IPv4 traddr=<JBOF_IP> trsvcid=4420 subnqn=<NQN>'     -t 30
```

Test I/O sizes:

```text
4 KiB
64 KiB
128 KiB
256 KiB
1 MiB
```

Test queue depths:

```text
1
4
16
32
64
128
```

Query dynamically:

```c
spdk_nvme_ns_get_sector_size(ns);
spdk_nvme_ns_get_max_io_xfer_size(ns);
spdk_nvme_ctrlr_get_max_xfer_size(ctrlr);
spdk_nvme_ctrlr_get_max_sges(ctrlr);
spdk_nvme_ns_get_optimal_io_boundary(ns);
```

### Pass criteria

- Stable SPDK NVMe-oF communication.
- Correct data.
- Known useful I/O size and queue-depth ranges.
- No NVMe/RDMA transport errors.

## 6. Stage 3 — Establish a GDS Direct-to-GPU Reference

Use NVIDIA GPUDirect Storage as a known-good control path:

```text
NVMe JBOF
   |
   | NVMe-oF
   v
Linux NVMe-RDMA
   |
   v
GDS / cuFile
   |
   v
GPU HBM
```

This is not the final architecture, but it proves the hardware stack can achieve JBOF-to-GPU transfer.

Use `gdsio`.

Example:

```bash
gdsio     -D /mnt/gds/test     -d 0     -w 1     -s 1G     -i 1M     -x 0     -I 0     -T 30
```

Compare with a CPU-mediated transfer mode.

### Pass criteria

- GDS reads from NVMe-oF-backed storage into GPU memory.
- Throughput is stable.
- GPU PCIe RX traffic is visible.
- CPU involvement is lower than the staged-copy path.

## 7. Stage 4 — Verify That GDS Is Really Direct

Run:

```bash
gdsio ... &
PID=$!
gds_stats -p $PID -l 3
```

Monitor GPU PCIe traffic:

```bash
nvidia-smi dmon -i 0 -s putcm
```

Also monitor NIC RX, CPU utilization, host memory bandwidth, and GDS bounce-buffer counters.

Desired result:

```text
JBOF network traffic     = high
GPU PCIe RX              = high
GDS direct path          = active
GDS bounce usage         = zero / negligible
CPU utilization          = relatively low
```

## 8. Stage 5 — Verify Alignment Behavior

Run a controlled matrix:

| Test | GPU Offset | Storage Offset | I/O Size |
|---|---:|---:|---:|
| A | 0 | 0 | 4 KiB |
| B | 0 | 0 | 64 KiB |
| C | 0 | 0 | 128 KiB |
| D | 0 | 0 | 1 MiB |
| E | +4 KiB | +4 KiB | 1 MiB |
| F | deliberately unaligned | aligned | 1 MiB |
| G | aligned | deliberately unaligned | 1 MiB |
| H | aligned | aligned | deliberately unaligned |

The goal is to prove that instrumentation can distinguish a direct path from a bounce/fallback path.

## 9. Stage 6 — Minimal SPDK Fixed-LBA Reader

Implement:

```text
spdk_fixed_lba_read
```

Initially use ordinary SPDK DMA-safe host memory.

The program should:

1. initialize SPDK;
2. connect to one NVMe-oF subsystem;
3. select one namespace;
4. allocate one qpair;
5. read one known LBA range;
6. verify the content;
7. exit.

Keep the first test simple:

```text
1 GPU
1 ConnectX port
1 JBOF
1 namespace
1 qpair
1 fixed LBA
1 buffer
```

## 10. Stage 7 — Deterministic Test Data

Populate a known LBA range with deterministic content.

Example:

```text
Block 0:
0x00000000
0x00000001
0x00000002
...

Block 1:
0x00001000
0x00001001
...
```

After the READ, verify inside the GPU:

```text
NVMe READ
   |
   v
GPU HBM
   |
   v
CUDA checksum kernel
   |
   v
small digest
   |
   v
CPU comparison
```

Only copy the small checksum result to the CPU.

## 11. Stage 8 — GPU RDMA Memory Registration

Implement:

```text
gpu_rdma_memory_test
```

Its responsibility is only:

```text
GPU allocation
      |
      v
GPU/RDMA registration
      |
      v
RDMA MR
      |
      +--> address
      +--> lkey
      +--> rkey
```

Possible implementation mechanisms:

- DMA-BUF
- NVIDIA peer-memory
- CUDA VMM plus an exported/shareable allocation

Keep this test independent from SPDK until it works.

## 12. Stage 9 — SPDK GPU Memory-Domain Integration

Study and use:

```text
spdk_memory_domain_create()
spdk_memory_domain_set_translation()
spdk_nvme_ctrlr_get_memory_domains()
spdk_nvme_ns_cmd_read_ext()
```

Required conceptual translation:

```text
GPU virtual address
       |
       v
GPU memory-domain provider
       |
       v
RDMA-accessible memory representation
       |
       v
SPDK NVMe/RDMA transport
```

The translation must not allocate and copy through host memory.

## 13. Stage 10 — First Direct SPDK NVMe READ into GPU HBM

Target call:

```cpp
spdk_nvme_ns_cmd_read_ext(
    ns,
    qpair,
    gpu_ptr,
    TEST_LBA,
    TEST_BLOCK_COUNT,
    completion_cb,
    request,
    &opts);
```

Conceptually:

```cpp
opts.memory_domain = gpu_memory_domain;
opts.memory_domain_ctx = gpu_context;
```

Minimal flow:

```text
allocate GPU buffer
        |
register for RDMA
        |
create SPDK GPU memory domain
        |
connect to JBOF
        |
issue NVMe READ
        |
poll completion
        |
CUDA checksum
        |
PASS / FAIL
```

## 14. How to Prove the SPDK Path Is Truly Direct

Require all of these observations:

1. NVMe-oF RX is visible on the GPU-node NIC.
2. GPU PCIe RX rises during the READ.
3. CUDA checksum verifies correct HBM data.
4. The application has no host payload allocation.
5. GPU memory is registered with the RDMA provider.
6. The payload path contains no `memcpy()`, `cudaMemcpy()`, or `cudaMemcpyAsync()`.
7. Host DRAM bandwidth does not scale approximately with storage throughput.
8. Failure of GPU registration causes I/O failure, not silent fallback.

Strong supporting evidence:

```text
NIC RX       ~= storage throughput
GPU PCIe RX  ~= storage throughput
Host DRAM    ~= baseline
```

Suspicious evidence:

```text
JBOF throughput ~= 20 GB/s
Host DRAM       ~= 20 GB/s
```

which may indicate:

```text
JBOF -> Host DRAM -> GPU
```

## 15. Mandatory Negative Test

After direct GPU READ works, intentionally make GPU RDMA registration fail.

Expected:

```text
NVMe READ fails
```

Not acceptable:

```text
SPDK silently uses host DRAM
and still succeeds
```

For the PoC:

```cpp
if (!direct_gpu_dma_possible)
    return -ENOTSUP;
```

Do not provide a fallback path.

## 16. Performance Matrix

Test I/O sizes:

```text
4 KiB
64 KiB
128 KiB
256 KiB
1 MiB
4 MiB
maximum NVMe transfer size
```

Test queue depths:

```text
1
4
16
32
64
128
```

Compare:

```text
A. Existing:
JBOF -> Object/Data Node -> GPU

B. Host bounce:
JBOF -> GPU host DRAM -> GPU

C. Proposed:
JBOF -> GPU HBM
```

Measure:

- GB/s
- IOPS
- average latency
- p99 latency
- CPU utilization
- GPU PCIe RX
- NIC RX
- host DRAM bandwidth
- NVMe errors
- RDMA errors
- checksum failures

## 17. Agent Work Breakdown

Give the implementation agent these tasks in order:

1. Create `00_inventory.sh`.
2. Run GPU-backed RDMA bandwidth testing.
3. Run SPDK NVMe-oF host-memory baseline.
4. Run GDS direct-to-GPU reference test.
5. Run alignment matrix.
6. Implement `gpu_rdma_memory_test`.
7. Implement `spdk_fixed_lba_read`.
8. Implement CUDA checksum validation.
9. Implement the SPDK GPU memory-domain provider.
10. Replace the host payload with GPU HBM.
11. Add explicit memory-domain and MR logging.
12. Add the no-fallback negative test.
13. Run size matrix.
14. Run queue-depth matrix.
15. Compare GDS-direct, SPDK-host, and SPDK-GPU results.

## 18. Suggested Machine-Readable Result

Every experiment should produce JSON.

Example:

```json
{
  "test": "spdk_gpu_read",
  "io_size": 1048576,
  "queue_depth": 1,
  "lba_size": 4096,
  "bytes": 1048576,
  "checksum_ok": true,
  "gpu_memory_domain": true,
  "rdma_registration": true,
  "host_payload_buffer": false,
  "host_bounce_detected": false,
  "gpu_pcie_rx_bytes": 1048576,
  "nic_rx_bytes": 1048576,
  "latency_us": 0,
  "throughput_gbps": 0,
  "result": "PASS"
}
```

## 19. Milestone 1

Do not initially implement object metadata, multipath, RAID, multiple GPUs, or multiple JBOFs.

Milestone 1 is only:

```text
Known LBA on one JBOF
          |
          | NVMe-oF / RDMA
          v
One GPU-node ConnectX
          |
          | GPUDirect RDMA
          v
1-MiB GPU allocation
          |
          v
CUDA checksum
          |
          v
PASS
```

If this succeeds with no host bounce, the core architectural hypothesis has been validated.

## 20. Final Pass/Fail Definition

The PoC is **PASS** only when all of these are true:

```text
[PASS] JBOF NVMe READ completes.

[PASS] Payload resides in GPU HBM.

[PASS] CUDA checksum matches expected data.

[PASS] RDMA NIC directly accesses registered GPU memory.

[PASS] No Object/Data Node exists in the payload path.

[PASS] No application host payload buffer exists.

[PASS] No memcpy/cudaMemcpy payload operation exists.

[PASS] No hidden SPDK bounce-buffer path is detected.

[PASS] Host DRAM bandwidth remains near baseline.

[PASS] Failure of GPU registration causes I/O failure,
       not silent fallback.
```

The target result is:

```text
NVMe SSD
   |
   v
JBOF NVMe-oF Target
   |
   | RDMA
   v
GPU-node NIC
   |
   | GPUDirect RDMA
   v
GPU HBM
```

## References

- NVIDIA GPUDirect Storage Getting Started  
  https://docs.nvidia.com/gpudirect-storage/getting-started/

- NVIDIA GPUDirect Storage Configuration Guide  
  https://docs.nvidia.com/gpudirect-storage/configuration-guide/

- NVIDIA GPUDirect Storage Troubleshooting Guide  
  https://docs.nvidia.com/gpudirect-storage/troubleshooting-guide/

- NVIDIA GPUDirect Storage Best Practices  
  https://docs.nvidia.com/gpudirect-storage/best-practices-guide/

- NVIDIA GPUDirect RDMA  
  https://docs.nvidia.com/cuda/gpudirect-rdma/

- SPDK NVMe Driver  
  https://spdk.io/doc/nvme.html

- SPDK NVMe API  
  https://spdk.io/doc/nvme_8h.html

- SPDK DMA / Memory Domain API  
  https://spdk.io/doc/dma_8h.html

- SPDK NVMe Extended I/O Options  
  https://spdk.io/doc/structspdk__nvme__ns__cmd__ext__io__opts.html
