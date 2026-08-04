# Agent runbook: kvopt fabric benchmark (autonomous, cluster-side)

You are the cluster-side agent, running on the INITIATOR. Your mission,
in order: (0) verify prerequisites, (1) ensure both hosts are built,
(2) run the fabric comparison, (3) judge it against the PASS gates,
(4) on PASS and if instructed, run the full suite, (5) type back
summaries only. Do each phase's checks — never assume.

Air-gap rules: raw CSVs and logs stay on this host. Only the type-back
blocks the scripts print (plus failure signatures quoted from logs)
leave the cluster.

Hard rules — never, under any circumstances:
- bare `pkill spdk_tgt` / `pkill nvmf_tgt` (kills other work; scope by
  socket only: `pkill -f "nvmf_tgt.*kvopt_tgt.sock"`)
- write anything into `/home/*/cpcs_paper/` (read-only seeds)
- use port 4420 or any `/var/tmp/vslm_*` socket (vslm-eval's)
- shrink `vm.nr_hugepages`
- start work while another campaign runs (Phase 0 check)

---

## Phase 0 — prerequisites (VERIFY each)

```bash
cd <kvopt-repo>/experiments/cluster
grep -A1 'trtype' ../../cpcs_paper/experiments/cpcs/inventories/real_cluster.yaml
                              # expect: trtype: RDMA / traddr: 10.10.100.1
bash -c 'source ./cluster_kvopt.env && echo "$TRTYPE $TRADDR:$TRSVCID $DPU_SSH"'
                              # expect: RDMA 10.10.100.1:4430 ubuntu@10.1.10.37
ssh ubuntu@10.1.10.37 hostname             # DPU reachable
pgrep -a -f cpcs_experiments && echo BUSY  # must be EMPTY — else STOP, report
ssh ubuntu@10.1.10.37 "ss -ltn | grep ':4430 '" && echo PORT_BUSY   # must be empty
```

If PORT_BUSY: a stale kvopt target. `ssh ubuntu@10.1.10.37 'sudo pkill -f
"nvmf_tgt.*kvopt_tgt.sock"'` (socket-scoped), re-check, proceed.

## Phase 1 — build state (skip prepare only if BOTH hold on BOTH hosts)

```bash
ls ~/kvopt/spdk/build/bin/kvopt_bench && grep '^CONFIG_RDMA?*=y' ~/kvopt/spdk/mk/config.mk
ssh ubuntu@10.1.10.37 'ls /home/ubuntu/kvopt/spdk/build/bin/nvmf_tgt && grep "^CONFIG_RDMA?*=y" /home/ubuntu/kvopt/spdk/mk/config.mk'
```

Missing or no `CONFIG_RDMA=y` (pre-RDMA builds lack it) → run prepare:

```bash
BUNDLE=/path/to/kvopt-thin.bundle bash prepare_kvopt_cluster.sh
```

PASS gate: both summary lines show `nvmf_tgt=yes kvopt_bench=yes build=OK`
(the initiator line reports kvopt_bench, the DPU line nvmf_tgt — both
must be yes on their host). Fix playbook:
- `ERR=bundle_fetch` → seed lacks the fork base; rerun with
  `BUNDLE=kvopt-full.bundle`.
- `ERR=no_seed_repo` → set `INIT_SEED_REPO`/`DPU_SEED_REPO` to the real
  cpcs_paper/spdk paths.
- `build=FAIL` → quote the `FAILtail:` line in the typeback and STOP.

## Phase 2 — run the comparison

```bash
bash compare_fabrics.sh            # quick suite x2 legs, ~30 min at REPS=5
```

Healthy output per leg: preflight lines → `verify <mode> PASS` x5 →
`baseline rep i/REPS done` xREPS → leg `rc=0`. Then one combined table.

## Phase 3 — PASS gates (judge before reporting success)

Per leg, on this host under `~/kvopt_results/fabric_cmp_<stamp>/<LEG>/`:

1. All five `verify <mode> PASS` lines. **Any verify FAIL → STOP**
   (data corruption beats performance): typeback the failing
   `verify_<mode>.log` tail + `/var/tmp/kvopt_tgt.log` tail from the
   DPU; do not run more benchmarks.
2. `baseline.csv`: every row `errors == 0`; `cmds_per_req` exactly
   64 / 16 / 16 / 16 / 8 by mode; all 5 modes present.
3. Comparison table has numbers (not FAILED) for every mode on every
   healthy leg.

An entire leg FAILED is a *finding*, not an abort — the other leg's
numbers stand. For a FAILED RDMA leg gather, in order:
`ssh ubuntu@10.1.10.37 'ibv_devices; ip addr show | grep 10.10.100'`,
ping 10.10.100.1 from here, and the connect error from the leg's
`verify_partial.log` — quote all three in the typeback. Known limitation:
`kvopt_bench` does not bind a source address; if the error indicates
route/binding (cross-subnet RoCE), report exactly that — the operator
has a fix queued. Reference fallback the operator may request:
`TCP_TRADDR=10.1.10.37 bash compare_fabrics.sh`.

Do NOT gate on which mode is faster — orderings are results, not health.

## Phase 4 — full suite (only on Phase-3 PASS and if instructed)

```bash
SUITE=full bash compare_fabrics.sh          # adds E1 + E4/E5 per leg, ~2 h
```

Expected-and-normal during sweeps: `FAILED: qd=2 mode=fused` — a fused
pair needs two SQ slots, a depth-2 queue holds one (NVMe N−1 rule).
Also cosmetic: `pci_event ... SO_RCVBUF` lines.

## Phase 5 — typeback (the ONLY thing that leaves the cluster)

Paste verbatim: the prep summary block (if Phase 1 ran), each leg's
`kvopt SUMMARY` block, the `FABRIC COMPARISON` table, and any failure
signatures collected above. State the results directory path so the
operator can request more later. Raw files stay.
