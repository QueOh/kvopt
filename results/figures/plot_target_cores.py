#!/usr/bin/env python3
"""Target-core scaling of NVMe-oF/RDMA throughput (CRC on), with the
line rate and the CRC-off peak as references.

Reads results/rdma-throughput-cores-<date>.csv (series,cores,GBps).
"""
import csv
import sys
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

HERE = Path(__file__).resolve().parent
CSV = Path(sys.argv[1]) if len(sys.argv) > 1 else HERE.parent / "rdma-throughput-cores-20260828.csv"
OUT = HERE / "target-cores-throughput.png"

cores, gbps = [], []
crc_off_peak = line_rate = None
for r in csv.DictReader(open(CSV)):
    if r["series"] == "crc_on":
        cores.append(int(r["cores"]))
        gbps.append(float(r["GBps"]))
    elif r["series"] == "crc_off_peak":
        crc_off_peak = float(r["GBps"])
    elif r["series"] == "line_rate":
        line_rate = float(r["GBps"])

pairs = sorted(zip(cores, gbps))
cores = [c for c, _ in pairs]
gbps = [g for _, g in pairs]
min_cores, min_gbps = pairs[0]
crc_on_peak = max(gbps)
crc_cost = (crc_off_peak - crc_on_peak) / crc_off_peak * 100

fig, ax = plt.subplots(figsize=(7.8, 4.8))
ax.set_title("NVMe-oF/RDMA target throughput vs target cores (CRC on)")

ax.plot(cores, gbps, "o-", color="#1f77b4", lw=2, ms=6, label="measured, CRC on")
ax.axhline(line_rate, color="#7f7f7f", ls="--", lw=1.3)
ax.axhline(crc_off_peak, color="#d62728", ls=":", lw=1.3)

ax.set_xscale("log", base=2)
ax.set_xticks(cores, [str(c) for c in cores])
ax.minorticks_off()
ax.set_ylim(0, 27.5)
ax.set_xlabel("target cores")
ax.set_ylabel("throughput (GB/s)")
ax.grid(True, which="major", alpha=0.3)

core_word = "core" if min_cores == 1 else "cores"
ax.annotate(f"{min_gbps:.1f} GB/s @ {min_cores} {core_word}\n= {min_gbps / line_rate * 100:.0f}% of line rate",
            xy=(min_cores, min_gbps), xytext=(1.6, 13.5),
            arrowprops=dict(arrowstyle="->", color="#1f77b4"), color="#1f77b4")
ax.text(46, line_rate + 0.45, f"line rate {line_rate:.0f} GB/s (200 GbE)",
        ha="right", color="#555555", fontsize=9)
ax.text(2, crc_off_peak - 0.55, f"peak without CRC: {crc_off_peak:.1f} GB/s"
        f"  (CRC cost −{crc_cost:.1f}%)",
        ha="left", va="top", color="#d62728", fontsize=9)

axr = ax.twinx()
axr.set_ylim(0, 27.5 / line_rate * 100)
axr.set_yticks([0, 25, 50, 75, 100])
axr.set_ylabel("% of line rate")

ax.legend(loc="lower right")
fig.tight_layout()
fig.savefig(OUT, dpi=150)
print(f"wrote {OUT}")
