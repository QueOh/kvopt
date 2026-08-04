# Running the kvopt benchmark

What it measures: five schemes for gathering N KV-cache objects per
application request over NVMe-oF/TCP (`partial`, `copy-read`,
`slm-copy-read`, `fused`, `vector`) — see `docs/design/` for the design
and §3 (`03-evaluation.md`) for the experiment definitions E1–E5.

All schemes are driven by one app, `spdk/build/bin/kvopt_bench`, against
an `nvmf_tgt` brought up by `spdk/test/kvopt/setup_target.sh`
(ns 1..8 = sources, ns 9 = malloc staging, ns 10 = SLM staging).

## 0. Build (any Linux host; macOS cannot build SPDK)

```bash
cd spdk && ./configure && make -j$(nproc)      # needs meson, ninja, pyelftools,
                                               # autotools (apt works; pip may be
                                               # TLS-intercepted on Samsung net)
sudo HUGEMEM=1024 PCI_ALLOWED=none scripts/setup.sh   # once per boot
```

In the dev VM (`vm/`), use `spdk/test/kvopt/vm_build.sh` instead — it
delta-syncs to `~/kvopt/spdk` and preserves incremental build state.

## 1. Environments

| where | how |
|---|---|
| single Linux host / dev VM | `sudo test/kvopt/verify.sh` then `sudo test/kvopt/run_benchmark.sh --local-target --out out.csv` |
| paper vagrant split env | `cat experiments/vm-split/smoke_kvopt_target.sh \| vagrant ssh target -c 'cat > /tmp/s.sh && SUITE=quick bash /tmp/s.sh'` (tree at `~/kvopt-spdk`, port 4430) |
| real cluster (air-gapped) | `experiments/cluster/README.md` — `prepare_kvopt_cluster.sh` once, then `run_kvopt_cluster.sh` (single fabric) or `compare_fabrics.sh` (RDMA + TCP legs, combined table); defaults come from `cpcs_paper/.../inventories/real_cluster.yaml` |

**Always run `verify.sh` (or the runner's verify phase) after any target
code change** — it checks gathered payloads byte-for-byte against a
written pattern (malloc sources; null sources return garbage by design).

## 2. kvopt_bench flags

```
-r <trid>   "trtype:TCP adrfam:IPv4 traddr:A trsvcid:P subnqn:N"   (required)
-M <mode>   partial | copy-read | slm-copy-read | fused | vector   (required)
-N objects (8)   -O first source nsid (1)   -C chunk blocks (32)
-K rounds/request (8)   -B base LBA (0)
-S staging nsid (9)     -L SLM nsid (10)
-R rounds in flight (2) -Q request slots (1)   [Q*R <= 64]
-D SQ depth (0 = SPDK default; >= 2; models the device queue limit)
-t seconds (10)  -w warmup seconds (2)  -n stop after n requests
-V verify one request (malloc sources only)   -c FILE append CSV
-m core mask     -H no hugepages (+ -s MB)
```

One *request* = N x (K x C blocks); with defaults 8 x 1 MiB = 8 MiB.

## 3. Experiment recipes (E1–E5 of docs/design/03-evaluation.md)

Sweep scripts live in `spdk/test/kvopt/`; with `TRADDR` set they use a
running target, otherwise they bring one up locally. Common env:
`TRADDR TRSVCID NQN APP_ARGS TGT_CORE_MASK TIME WARMUP OUT MODES`.

```bash
# baselines (pipelined / isolated batches)
run_benchmark.sh --local-target --out base_r2.csv          # R=2
run_benchmark.sh --local-target -R 1 --out base_r1.csv     # R=1

# E1 — chunk-size sweep (command amplification axis)
CHUNKS="1 2 4 8 16 32" R=2 OUT=chunk.csv sweep_chunk.sh

# E2/E3 — SQ-depth sweep at app-level load R=4 x Q=4
QDS="2 4 8 16 32 64" OUT=qd.csv sweep_qd.sh                # C=32 (byte-bound)
C=2 K=128 QDS="2 4 8 16 32" OUT=qd8k.csv sweep_qd.sh       # C=8KiB (command-bound)

# E4/E5 — SATURATED SQ sweeps (every mode offers >= 64 outstanding)
C=32 K=8  R=8 QSLOTS=8 QDS="2 4 8 16 32 64" OUT=sat128k.csv sweep_qd.sh
C=2 K=128 R=8 QSLOTS=8 QDS="2 4 8 16 32 64" OUT=sat8k.csv  sweep_qd.sh
```

For quotable numbers run every point >= 3 times (5 on the cluster —
`REPS` in the cluster runner) and take medians; see `docs/ANALYSIS.md`.

## 4. Known structural behaviors (not bugs)

- `fused` at `-D 2` dies by design: a fused pair needs two SQ slots and a
  depth-2 queue holds one command (NVMe N−1 rule). The target drops the
  connection; sweeps mark the point FAILED and continue.
- `pci_event ... SO_RCVBUF` messages from the app are cosmetic.
- Co-residency rules (shared boxes): never bare-`pkill` SPDK targets,
  keep the kvopt namespace (port 4430, own NQN/sock), cap target memory
  with `TGT_MEM_MB`, never shrink a host's provisioned hugepage pool.
