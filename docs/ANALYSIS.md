# Analyzing kvopt benchmark results

## 1. Data files

`kvopt_bench -c FILE` appends one CSV row per run (header written on
first use). Collected data lives in `results/`:

| file | experiment | provenance |
|---|---|---|
| `kvopt-vm-loopback-20260728.csv` / `-R1-…` | baselines R=2 / R=1 | `vm` (kvopt-bench VM) |
| `kvopt-vm-chunk-sweep-…` | E1 | `vm` |
| `kvopt-vm-qd-sweep-…` / `-qd-c8k-…` | E2 / E3 | `vm` |
| `kvopt-vm-qdsat-c128k-…` / `-c8k-…` (+`-rep2-`) | E4 / E5, two reps | `vm` |
| `paper-env-20260729/baseline.csv` | baseline | `vm_split` (paper target VM) |
| cluster runs → `~/kvopt_results/<stamp>/` on the initiator | — | `real_cluster` |

**Provenance rule** (inherited from the paper tooling): never merge or
average across provenances. Compare shapes/orderings, not absolutes.

## 2. CSV schema

Two vintages: rows before 2026-07-29 lack the `qd` column. Parse by
header name, not position (`csv.DictReader`).

| column | meaning |
|---|---|
| `mode` | partial / copy-read / slm-copy-read / fused / vector |
| `N`, `C_blocks`, `K` | objects, chunk size in 4 KiB blocks, batches per request |
| `R`, `Q` | batches in flight per slot, concurrent request slots |
| `qd` | requested SQ depth (`0` = SPDK default) |
| `elapsed_s` | measurement window (excludes warmup; includes drain tail) |
| `requests`, `rounds`, `cmds` | completed in the window (`rounds` = batches) |
| `MBps` | payload MB/s = rounds x N x C / elapsed |
| `round_*_us` | batch latency: first submit → last completion (min/avg/p50/p90/p99/max as present) |
| `req_avg_us`, `req_p99_us` | request latency: first batch submit → last batch completion |
| `cmds_per_req` | measured SQEs per request |
| `errors` | failed completions + verify failures (any nonzero → discard the row) |

Derived: `req/s = requests / elapsed_s`; with default geometry
1 request = 8 MiB, so `MB/s ≈ req/s x 8`.

## 3. Sanity invariants (check before interpreting)

1. `errors == 0` for every kept row (exception: `fused` at `qd=2` is
   *expected* to fail structurally — exclude that cell, don't average it;
   a dying run can log a stray handful of requests, so also drop any
   row with `req/s < 10`).
2. `cmds_per_req` exact: partial `8K`, copy modes and fused `2K`,
   vector `K` (defaults: 64 / 16 / 16 / 16 / 8).
3. All modes in one comparison carry identical `N, C_blocks, K` —
   identical payload per request.
4. `rounds ≈ requests x K` (small drift from the in-flight tail is fine).

## 4. Method

- **Reps**: >= 3 per point (5 on the cluster), report the **median**;
  single cells vary ±10–30 % on shared hosts. Jitter concentrates in the
  staging modes (their DRAM store-and-forward pass) and at low QD.
- **Compare** modes at identical workload knobs; the interesting ratios
  are per-axis: vector÷partial vs chunk size (E1), vs SQ depth (E5).
- **cmds/s ceilings** explain the shapes: e.g. partial's plateau is the
  target's command-processing limit (`req/s x cmds_per_req`), vector
  converts the same budget into ~8x payload per slot.

## 5. What each experiment shows (reading guide)

| experiment | axis | expected signature |
|---|---|---|
| baseline R=2 vs R=1 | pipelining | R=2 helps partial/vector, can hurt staging modes on a 1-core target; fused ≈ copy-read on loopback (saved turnaround ≪ RTT) |
| E1 chunk sweep | command amplification `N x S/C` | vector÷partial grows as chunks shrink (measured: 1.05x @128 KiB → 1.76x @4 KiB); staging modes bundle below |
| E2/E3 (R=4 x Q=4) | SQ depth, *offered load differs per mode* | only partial saturates high QD — treat as app-level-load study, prefer E4/E5 for queue conclusions |
| E4 saturated, 128 KiB | control | byte-path-bound: all modes flat vs QD, aggregation buys nothing |
| E5 saturated, 8 KiB | the headline | vector leads at every depth (~3x @qd2 → ~1.3x @qd64); partial worst of all modes at qd <= 4; fused floor at qd >= 4 |

Loopback caveat: fabric RTT ≈ 0, so fused's advantage over copy-read is
invisible; expect it to appear at R=1 on a real network.

## 6. Figures

`results/figures/plot_kvopt.py` regenerates the four PNGs
(baseline bars, E1, E4, E5) from the `results/*.csv` files — filenames
are pinned at the top of the script; point them at new vintages to
re-plot. It needs matplotlib:

```bash
python3 -m venv /tmp/viz && /tmp/viz/bin/pip install matplotlib
/tmp/viz/bin/python results/figures/plot_kvopt.py
```

Conventions baked in: one fixed color per mode across all figures
(colorblind-validated palette), mean line + per-rep dots, log2 axes,
failed cells (fused@qd2) filtered as "no data", `.png` at dpi 150. For
the paper pipeline, mirror `cpcs_paper`'s `make_figs.py` house style
(csv.DictReader + save both `.png` and `.pdf`).

Air-gap note: raw cluster CSVs stay on the initiator; only the
type-back summary (median per mode) and derived figures leave.
