#!/usr/bin/env python3
"""Checksum benchmark: elapsed time and derived throughput vs data size,
CRC32C (solid) vs IEEE (dashed), four execution variants.

Reads results/checksum-bench-<date>.csv (poly,variant,size_label,size_bytes,time_us).
"""
import csv
import sys
from collections import defaultdict
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.lines import Line2D

HERE = Path(__file__).resolve().parent
CSV = Path(sys.argv[1]) if len(sys.argv) > 1 else HERE.parent / "checksum-bench-20260902.csv"
OUT = HERE / "checksum-bench.png"

COLORS = {"serial": "#7f7f7f", "cpu_cpu": "#1f77b4", "gpu_cpu": "#ff7f0e", "gpu_gpu": "#2ca02c"}
LSTYLE = {"CRC32C": "-", "IEEE": "--"}

series = defaultdict(list)   # (poly, variant) -> [(bytes, us)]
labels = {}
for r in csv.DictReader(open(CSV)):
    series[(r["poly"], r["variant"])].append((int(r["size_bytes"]), float(r["time_us"])))
    labels[int(r["size_bytes"])] = r["size_label"]
for v in series.values():
    v.sort()
sizes = sorted(labels)

fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(12, 4.8))
fig.suptitle("Checksum compute: CRC32C vs IEEE across execution variants", y=0.98)

for (poly, var), pts in series.items():
    xs = [b for b, _ in pts]
    ax1.plot(xs, [t for _, t in pts], ls=LSTYLE[poly], color=COLORS[var], marker="o", ms=3.5)
    ax2.plot(xs, [b / t / 1000.0 for b, t in pts],  # B/us -> GB/s
             ls=LSTYLE[poly], color=COLORS[var], marker="o", ms=3.5)

for ax, ylab, title in ((ax1, "elapsed time (µs)", "elapsed time"),
                        (ax2, "throughput (GB/s)", "derived throughput")):
    ax.set_xscale("log", base=2)
    ax.set_yscale("log")
    ax.set_xticks(sizes, [labels[s] for s in sizes])
    ax.minorticks_off()
    ax.set_xlabel("data size (B)")
    ax.set_ylabel(ylab)
    ax.set_title(title)
    ax.grid(True, which="both", alpha=0.3)

handles = [Line2D([], [], color=COLORS[v], marker="o", ms=3.5, label=v)
           for v in ("serial", "cpu_cpu", "gpu_cpu", "gpu_gpu")]
handles += [Line2D([], [], color="black", ls="-", label="CRC32C"),
            Line2D([], [], color="black", ls="--", label="IEEE")]
ax1.legend(handles=handles, fontsize=8, ncol=2, loc="upper left")

fig.tight_layout()
fig.savefig(OUT, dpi=150)
print(f"wrote {OUT}")
