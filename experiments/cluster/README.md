# kvopt gather-scheme benchmark — real cluster

Runs the kvopt benchmark (branch `kvopt` of QueOh/spdk: cross-NS Copy,
fused Copy+Read, Vector Read + `kvopt_bench`) on the EPYC-initiator /
BlueField-3-DPU cluster.

**Default setup comes from the cluster inventory**
`cpcs_paper/experiments/cpcs/inventories/real_cluster.yaml` (the
`cpcs_paper` submodule; override the file with `INVENTORY=...`).
`cluster_kvopt.env` reads hosts/SSH, the seed repo paths
(`hosts.*.repo_path`), the fabric address (`nvmeof.traddr`), the target
core mask and the rep count (`runtime.*`) from it — via PyYAML when
available (the cluster initiator has it) or a line-based fallback.
Explicit env always wins; hardcoded fallbacks cover a checkout without
the submodule. Only the benchmark *identity* stays kvopt-specific so
runs never collide with vslm-eval: port 4430, kvopt NQN, own RPC socket.

Everything is namespaced away from the vslm/cpcs work: dedicated repos
(`~/kvopt/spdk`, `cpcs_paper/spdk` is a read-only seed), port **4430**,
NQN `nqn.2026-07.io.spdk:kvopt-bench`, sock `/var/tmp/kvopt_tgt.sock`.
Fabric is TCP via 10.1.10.37 (the RoCE path is down per cluster.env).

## 0. Get the code onto the cluster (air-gapped)

Carry in, via the usual channel:
- the kvopt repo (this directory arrives with it), and
- `kvopt-thin.bundle` (28 KB, sits next to this README; gitignored). It
  applies on top of fork base `15c7d7063`, which the `cpcs_paper/spdk`
  seeds already contain. Fallback if the seed is older:
  `kvopt-full.bundle` (89 MB).

On the cluster, point the submodule at the existing local paper checkout
instead of the network:

```bash
git config submodule.cpcs_paper.url /home/kyuho/cpcs_paper
git submodule update --init cpcs_paper
```

## 1. Prepare (once, on the initiator)

```bash
cd <paper>/experiments/kvopt
BUNDLE=/path/to/kvopt-thin.bundle bash prepare_kvopt_cluster.sh
```

Clones `~/kvopt/spdk` (initiator) and `/home/ubuntu/kvopt/spdk` (DPU)
from the local seeds, imports the kvopt commits from the bundle, seeds
submodules offline, builds both in parallel, prints a type-back line per
host (`nvmf_tgt=yes kvopt_bench=yes build=OK`).

## 2. Run (on the initiator)

```bash
bash run_kvopt_cluster.sh                # quick: verify + baseline x5 reps (~15 min)
SUITE=full bash run_kvopt_cluster.sh     # + chunk sweep + saturated QD sweeps (~50 min)
bash compare_fabrics.sh                  # BOTH transports over the data-path addr
                                         # (RDMA then TCP), one combined comparison table
```

`compare_fabrics.sh` runs the full suite once per transport over the
SAME address (`nvmeof.traddr` — the data-path interface), so only the
protocol changes between legs (override per leg with
`RDMA_TRADDR`/`TCP_TRADDR`). It ends with a per-mode median table plus
the RDMA/TCP ratio. A leg that cannot establish is reported FAILED and
the other leg still completes.

Phases: preflight (binaries, port 4430 free, DPU hugepages) → data
verify, all 5 modes, malloc sources → baseline ×REPS on null sources →
(full) E1/E4/E5 sweeps. The DPU target is started/stopped over SSH with
a socket-scoped teardown trap; raw CSVs stay on the initiator under
`~/kvopt_results/<stamp>/`; the run ends with a median-per-mode
**type-this-back** summary (air-gap: summaries only leave the cluster).

Tunables (env or `cluster_kvopt.env`): `TGT_CORE_MASK` (default 0xF),
`TGT_MEM_MB` (2048), `REPS` (5), `TIME_SEC` (10), `TRSVCID`, `APP_ARGS`.

## Handing this to an agent

`AGENT_RUNBOOK.md` (this directory) is a self-contained mission for a
cluster-side agent: prerequisites to verify, PASS gates, the fix
playbook for every known failure signature, and the air-gap typeback
format. Point the agent at that one file; it needs no other context.

## Notes

- The workload is protocol-overhead-focused (null sources). Real-SSD
  sources on the DPU (PM1743 namespaces) would need bdev_nvme attach
  wiring in `setup_target.sh` — not included yet.
- Provenance is `real_cluster`; keep separate from `vm_split`/`vm_smoke`
  results (the aggregation tooling refuses to merge provenances).
