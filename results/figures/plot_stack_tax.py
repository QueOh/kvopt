#!/usr/bin/env python3
"""Plot the QD1 NVMe-oF stack tax sweep (rdma-latency experiment).

Reads results/rdma-latency-sweep-<date>.csv and renders one figure:
left panel log-log avg latency of both legs, right panel the absolute
tax (bars) with the nvmf/raw ratio on a secondary axis.
"""
import csv
import sys
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

HERE = Path(__file__).resolve().parent
CSV = Path(sys.argv[1]) if len(sys.argv) > 1 else HERE.parent / "rdma-latency-sweep-20260827.csv"
OUT = HERE / "stack-tax-by-size.png"


def size_label(n):
    return f"{n // 1024}K" if n < 1048576 else f"{n // 1048576}M"


rows = list(csv.DictReader(open(CSV)))
sizes = [int(r["size_bytes"]) for r in rows]
nvmf = [float(r["nvmf_avg_us"]) for r in rows]
raw = [float(r["raw_avg_us"]) for r in rows]
tax = [float(r["tax_us"]) for r in rows]
ratio = [float(r["ratio"]) for r in rows]
labels = [size_label(s) for s in sizes]

fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(11, 4.4))
fig.suptitle("NVMe-oF/RDMA stack cost over the fabric floor (QD1, null bdev)", y=0.98)

# --- left: both legs, log-log ---------------------------------------
ax1.plot(sizes, nvmf, "o-", label="NVMe-oF read (leg A)", color="#1f77b4")
ax1.plot(sizes, raw, "s--", label="raw RDMA write (leg B)", color="#7f7f7f")
ax1.set_xscale("log", base=2)
ax1.set_yscale("log")
ax1.set_xticks(sizes, labels)
ax1.set_yticks([3, 5, 10, 20, 50, 90], ["3", "5", "10", "20", "50", "90"])
ax1.minorticks_off()
ax1.set_xlabel("I/O size (B)")
ax1.set_ylabel("avg latency (µs)")
ax1.grid(True, which="both", alpha=0.3)
ax1.legend()
ax1.set_title("avg latency vs size")

# --- right: tax bars + ratio line -----------------------------------
x = range(len(sizes))
mean_tax = sum(tax) / len(tax)
ax2.bar(x, tax, color="#2ca02c", alpha=0.8, label="tax = A − B (µs)")
ax2.axhline(mean_tax, color="#2ca02c", ls=":", lw=1.2)
ax2.annotate(f"mean {mean_tax:.2f} µs", (0.1, mean_tax + 0.08), color="#2ca02c")
ax2.set_xticks(list(x), labels)
ax2.set_xlabel("I/O size (B)")
ax2.set_ylabel("stack tax (µs)", color="#2ca02c")
ax2.set_ylim(0, max(tax) * 1.35)
ax2.set_title("stack tax stays flat; ratio → 1")

ax2r = ax2.twinx()
ax2r.plot(list(x), ratio, "d-", color="#d62728", label="ratio A/B")
ax2r.set_ylabel("nvmf / raw ratio", color="#d62728")
ax2r.set_ylim(1.0, 2.0)
for i in (0, len(ratio) - 1):
    ax2r.annotate(f"{ratio[i]:.2f}×", (i, ratio[i] + 0.04), color="#d62728", ha="center")

fig.tight_layout()
fig.savefig(OUT, dpi=150)
print(f"wrote {OUT}")
