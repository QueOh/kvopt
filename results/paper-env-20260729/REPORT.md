# kvopt gather-scheme benchmark — split-env target VM (quick suite)

**Provenance: `vm_split` (vslm-target VM, loopback). NOT mergeable with
`real_cluster` results.**

- Run: 2026-07-29, `smoke_kvopt_target.sh SUITE=quick` (piped in via the
  `manage.sh smoke` idiom), results dir `20260729_053201/`.
- Tree: `/home/vagrant/kvopt-spdk` (branch `kvopt` of QueOh/spdk), fully
  disjoint from the vslm work: port 4430, NQN
  `nqn.2026-07.io.spdk:kvopt-bench`, sock `/var/tmp/kvopt_tgt.sock`,
  target core 0x4 (`-s 1024` hugepage cap), bench app core 0x8
  (hugepage-free). The 2048-page hugepage pool was left untouched.
- Workload: N=8 objects x 1 MiB (8 MiB/request), C=128 KiB chunks, K=8
  batches, R=2 in flight, Q=1, null-bdev sources (protocol overhead only).
- Phase 1: data verify (malloc sources + pattern) — **all 5 modes PASS**.
- Phase 2 baseline (`baseline.csv`):

| mode | req/s | MB/s | batch avg µs | batch p99 µs |
|---|---|---|---|---|
| partial | 1454 | 11,633 | 162.2 | 381.3 |
| copy-read | 786 | 6,284 | 302.3 | 490.7 |
| slm-copy-read | 794 | 6,349 | 298.9 | 552.0 |
| fused | 871 | 6,970 | 276.0 | 445.3 |
| vector | **1808** | **14,459** | **130.7** | 234.7 |

Cross-check vs the kvopt-bench VM baseline (same params): ordering
identical; vector 1808 vs 1794 req/s, staging modes within ~5–15 %.
partial is somewhat lower here (1454 vs 1828), consistent with sharing
the box with more concurrent VMs.

Follow-ups: split mode (bench app on vslm-initiator VM, 192.168.56.22:4430)
requires resuming the paused initiator VM; `SUITE=full` adds the chunk
sweep and saturated QD sweeps. Real-cluster runs go through
`suites/vslm_eval/repro/prepare_cluster.sh` conventions (air-gap:
summaries only).
