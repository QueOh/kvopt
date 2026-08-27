# QD1 latency: NVMe-oF/RDMA read vs raw RDMA write

Measures what the NVMe-oF stack costs on top of the bare fabric, to
back the claim that the stack impact on latency is small. Both legs
move the same 4 KiB over the same NICs at QD1:

| leg | what runs | what the number contains |
|---|---|---|
| A `nvmf_read` | `spdk_nvme_perf -q 1 -o 4096 -w randread -L` against a **null bdev** | RDMA SEND (64 B command) + target SW + RDMA WRITE (4 KiB data) + RDMA SEND (16 B completion) + initiator SW |
| B `raw_rdma_write` | `ib_write_lat -R -s 4096` (perftest) | one one-sided 4 KiB RDMA WRITE (ping-pong / 2) |

A − B = command/completion messaging + SPDK target + initiator driver:
the "NVMe-oF stack tax". The null bdev removes media and memcpy from
leg A, so nothing but protocol and software is being measured.

## Run

```bash
# storage server (once per boot: sudo HUGEMEM=1024 spdk/scripts/setup.sh)
sudo env TRADDR=<server RDMA IP> experiments/rdma-latency/lat_target.sh
#   teardown: sudo experiments/rdma-latency/lat_target.sh --teardown

# initiator; TGT_SSH lets the script start the ib_write_lat server itself
sudo env TRADDR=<server RDMA IP> TGT_SSH=user@server \
     experiments/rdma-latency/lat_initiator.sh
```

Without `TGT_SSH` the script prints the exact `ib_write_lat` server
command to run on the target and waits for ENTER. `perftest` must be
installed on both hosts (`apt install perftest`).

Output: `results/rdma-latency-<timestamp>/` with both raw logs and
`summary.csv` (`test,trtype,size_bytes,qd,avg_us,p50_us,p99_us,p999_us,min_us,max_us`),
plus the derived line:

```
NVMe-oF stack cost over the fabric floor: X.XX us (Y.YYx of raw)
```

## Knobs

`SIZE` (both legs), `TIME`/`WARMUP` (leg A), `ITERS` (leg B),
`WORKLOAD`, `RAW_EXTRA` (e.g. `-d mlx5_1` device pick for perftest),
`SKIP_RAW=1`/`SKIP_NVMF=1`, `TRTYPE=TCP` (smoke only; raw leg
auto-skips). Port 4432, NQN `nqn.2026-07.io.spdk:kvopt-lat` - disjoint
from the bench (4430) and gpu-direct (4431) targets, so all three can
coexist on one server.

## Reading the numbers honestly

- Compare **p50 to t_typical** and avg to t_avg; ib_write_lat reports
  half of a write ping-pong, which is the accepted one-way figure.
- The claim holds when A − B is a few microseconds and stays flat
  across sizes; rerun with `SIZE=512` and `SIZE=131072` if a reviewer
  asks whether the tax scales with payload.
- Same subnet, same ports, no IOMMU surprises: the two legs must cross
  the identical physical path or the subtraction is meaningless.
- Leg A uses one dedicated core (`-c 0x1`) and QD1, so no queueing
  effects pollute the latency; do not raise QD here - that is a
  different experiment (E5 in the bench).
