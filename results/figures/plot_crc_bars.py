#!/usr/bin/env python3
"""Bar comparison of NVMe-oF/RDMA throughput with CRC on vs off at a given
target-core count.

Usage: plot_crc_bars.py [cores] [csv]   (defaults: 1 core, the 20260828 CSV)

CRC-on is measured per core count; the CRC-off value in the dataset is the
recorded peak (core count not logged), so its bar is labeled as such.

Reads results/rdma-throughput-cores-<date>.csv (series,cores,GBps).
"""
import csv
import sys
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

HERE = Path(__file__).resolve().parent
CORES = int(sys.argv[1]) if len(sys.argv) > 1 else 1
CSV = Path(sys.argv[2]) if len(sys.argv) > 2 else HERE.parent / "rdma-throughput-cores-20260828.csv"
OUT = HERE / f"crc-on-off-{CORES}core.png"

crc_on = crc_off = line_rate = None
for r in csv.DictReader(open(CSV)):
    if r["series"] == "crc_on" and r["cores"] == str(CORES):
        crc_on = float(r["GBps"])
    elif r["series"] == "crc_off_peak":
        crc_off = float(r["GBps"])
    elif r["series"] == "line_rate":
        line_rate = float(r["GBps"])

assert None not in (crc_on, crc_off, line_rate), f"missing series or {CORES}-core row in CSV"
crc_cost = (crc_off - crc_on) / crc_off * 100
core_word = "core" if CORES == 1 else "cores"

fig, ax = plt.subplots(figsize=(5.8, 4.8))
ax.set_title(f"NVMe-oF/RDMA target throughput at {CORES} {core_word},\nCRC on vs off")

labels = [f"CRC on\n({CORES} {core_word})", "CRC off\n(peak)"]
values = [crc_on, crc_off]
colors = ["#1f77b4", "#d62728"]
bars = ax.bar(labels, values, width=0.55, color=colors)

for bar, v in zip(bars, values):
    ax.text(bar.get_x() + bar.get_width() / 2, v + 0.4, f"{v:.2f}",
            ha="center", va="bottom", fontweight="bold")
    ax.text(bar.get_x() + bar.get_width() / 2, v / 2,
            f"{v / line_rate * 100:.0f}% of\nline rate",
            ha="center", va="center", color="white", fontsize=9)

ax.axhline(line_rate, color="#7f7f7f", ls="--", lw=1.3)
ax.text(0.98, line_rate + 0.35, f"line rate {line_rate:.0f} GB/s (200 GbE)",
        transform=ax.get_yaxis_transform(), ha="right",
        color="#555555", fontsize=9)

ax.text(0.5, (crc_on + crc_off) / 2 + 0.1,
        f"CRC cost −{crc_cost:.1f}%", ha="center", va="bottom",
        color="#333333", fontsize=9)

ax.set_ylim(0, 27.5)
ax.set_ylabel("throughput (GB/s)")
ax.grid(True, axis="y", alpha=0.3)
ax.set_axisbelow(True)

fig.tight_layout()
fig.savefig(OUT, dpi=150)
print(f"wrote {OUT}")
