#!/usr/bin/env python3
"""kvopt benchmark figures — light mode, validated categorical palette."""
import csv
import os
from collections import defaultdict

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

RES = os.path.expanduser("~/Workspace/kvopt/results")
OUT = os.path.join(RES, "figures")
os.makedirs(OUT, exist_ok=True)

SURFACE = "#fcfcfb"
TEXT = "#0b0b0b"
TEXT2 = "#52514e"
GRID = "#e7e6e3"

MODES = ["partial", "copy-read", "slm-copy-read", "fused", "vector"]
COLORS = {
    "partial": "#2a78d6",        # slot 1 blue
    "copy-read": "#eb6834",      # slot 2 orange
    "slm-copy-read": "#1baf7a",  # slot 3 aqua
    "fused": "#eda100",          # slot 4 yellow
    "vector": "#e87ba4",         # slot 5 magenta
}


def load(fname):
    """rows keyed by (mode, qd, C) -> req/s"""
    rows = []
    with open(os.path.join(RES, fname)) as f:
        for r in csv.DictReader(f):
            el = float(r["elapsed_s"])
            reqps = float(r["requests"]) / el if el > 0 else 0.0
            rows.append({
                "mode": r["mode"],
                "C": int(r["C_blocks"]),
                "qd": int(r.get("qd", 0)),
                "reqps": reqps,
            })
    return rows


def style_axes(ax):
    ax.set_facecolor(SURFACE)
    for s in ("top", "right"):
        ax.spines[s].set_visible(False)
    for s in ("left", "bottom"):
        ax.spines[s].set_color(GRID)
    ax.tick_params(colors=TEXT2, labelsize=9)
    ax.yaxis.grid(True, color=GRID, linewidth=0.8)
    ax.xaxis.grid(False)
    ax.set_axisbelow(True)


def line_fig(series, xticks, xlabel, title, subtitle, outfile, note=None,
             scatter=None):
    fig, ax = plt.subplots(figsize=(8.0, 4.6), dpi=150)
    fig.patch.set_facecolor(SURFACE)
    style_axes(ax)

    for mode in MODES:
        xs, ys = series.get(mode, ([], []))
        if not xs:
            continue
        ax.plot(xs, ys, color=COLORS[mode], linewidth=2, marker="o",
                markersize=6, markerfacecolor=COLORS[mode],
                markeredgecolor=SURFACE, markeredgewidth=1.2, label=mode,
                zorder=3)
        if scatter and mode in scatter:
            sx, sy = scatter[mode]
            ax.plot(sx, sy, linestyle="none", marker="o", markersize=3.5,
                    color=COLORS[mode], alpha=0.45, zorder=2)

    ax.set_xscale("log", base=2)
    ax.set_xticks(xticks)
    ax.set_xticklabels([str(t) for t in xticks])
    ax.minorticks_off()
    ax.set_xlabel(xlabel, fontsize=10, color=TEXT2)
    ax.set_ylabel("requests / s   (1 request = 8 MiB)", fontsize=10,
                  color=TEXT2)
    ax.set_ylim(bottom=0)
    ax.set_title(title, fontsize=12, color=TEXT, fontweight="bold", loc="left",
                 pad=18)
    ax.text(0, 1.02, subtitle, transform=ax.transAxes, fontsize=9,
            color=TEXT2)
    if note:
        ax.text(0.01, 0.02, note, transform=ax.transAxes, fontsize=8,
                color=TEXT2, style="italic")
    leg = ax.legend(loc="upper left", bbox_to_anchor=(1.01, 1.0), fontsize=9,
                    frameon=False, labelcolor=TEXT)
    fig.tight_layout()
    fig.savefig(os.path.join(OUT, outfile), facecolor=SURFACE,
                bbox_inches="tight")
    plt.close(fig)
    print("wrote", outfile)


# ---- F1: E1 chunk sweep -------------------------------------------------
rows = load("kvopt-vm-chunk-sweep-20260729.csv")
series = {}
for mode in MODES:
    pts = sorted((r["C"] * 4, r["reqps"]) for r in rows if r["mode"] == mode)
    series[mode] = ([p[0] for p in pts], [p[1] for p in pts])
line_fig(series, [4, 8, 16, 32, 64, 128], "chunk size (KiB, log2)",
         "E1 — Command amplification: throughput vs chunk size",
         "N=8 objects x 1 MiB, K = 1 MiB / chunk, R=2, Q=1, SQ depth default. "
         "partial issues 8x1MiB/C cmds per request; vector 1 per batch.",
         "e1-chunk-sweep.png")

# ---- F2/F3: saturated QD sweeps (mean of two reps, reps as faint dots) --
for tag, rep1, rep2, title, sub, out in [
    ("c8k",
     "kvopt-vm-qdsat-c8k-20260729.csv", "kvopt-vm-qdsat-c8k-rep2-20260729.csv",
     "E5 — SQ-depth limit, command-bound (8 KiB chunks)",
     "R=8, Q=8: every mode offers >= 64 outstanding commands — SQ full at "
     "every depth. Line = mean of 2 runs, dots = individual runs.",
     "e5-qd-saturated-8k.png"),
    ("c128k",
     "kvopt-vm-qdsat-c128k-20260729.csv",
     "kvopt-vm-qdsat-c128k-rep2-20260729.csv",
     "E4 — SQ-depth control, byte-bound (128 KiB chunks)",
     "Same saturation (R=8, Q=8). Byte path of the 1-core target dominates: "
     "queue depth and command count stop mattering.",
     "e4-qd-saturated-128k.png"),
]:
    r1 = load(rep1)
    r2 = load(rep2)
    vals = defaultdict(dict)
    for r in r1 + r2:
        vals[r["mode"]].setdefault(r["qd"], []).append(r["reqps"])
    series, scatter = {}, {}
    for mode in MODES:
        # a failed point (connection torn down) may record a stray handful
        # of requests before dying — treat anything < 10 req/s as no data
        qds = sorted(q for q, v in vals[mode].items()
                     if all(x > 10 for x in v))
        series[mode] = (qds, [sum(vals[mode][q]) / len(vals[mode][q])
                              for q in qds])
        sx, sy = [], []
        for q in qds:
            for v in vals[mode][q]:
                sx.append(q)
                sy.append(v)
        scatter[mode] = (sx, sy)
    line_fig(series, [2, 4, 8, 16, 32, 64], "SQ depth (commands, log2)",
             title, sub, out,
             note="fused has no QD=2 point: a fused pair needs two queue "
                  "slots; a depth-2 queue holds one command (N-1 rule).",
             scatter=scatter)

# ---- F4: baselines bar chart -------------------------------------------
base_r2 = load("kvopt-vm-loopback-20260728.csv")
base_r1 = load("kvopt-vm-loopback-R1-20260729.csv")
r2v = {r["mode"]: r["reqps"] for r in base_r2}
r1v = {r["mode"]: r["reqps"] for r in base_r1}

fig, ax = plt.subplots(figsize=(8.0, 4.2), dpi=150)
fig.patch.set_facecolor(SURFACE)
style_axes(ax)
x = range(len(MODES))
w = 0.38
ax.bar([i - w / 2 - 0.01 for i in x], [r2v[m] for m in MODES], width=w,
       color="#2a78d6", label="R=2 (pipelined batches)", zorder=3)
ax.bar([i + w / 2 + 0.01 for i in x], [r1v[m] for m in MODES], width=w,
       color="#eb6834", label="R=1 (isolated batches)", zorder=3)
ax.set_xticks(list(x))
ax.set_xticklabels(MODES, fontsize=9, color=TEXT)
ax.set_ylabel("requests / s   (1 request = 8 MiB)", fontsize=10, color=TEXT2)
ax.set_title("Baseline — 128 KiB chunks, Q=1, SQ depth default",
             fontsize=12, color=TEXT, fontweight="bold", loc="left", pad=18)
ax.text(0, 1.02, "N=8 objects x 1 MiB per request, K=8 batches, "
        "TCP loopback, null sources, 1 target core.",
        transform=ax.transAxes, fontsize=9, color=TEXT2)
ax.set_ylim(0, 2150)
ax.legend(loc="upper center", fontsize=9, frameon=False, labelcolor=TEXT)
fig.tight_layout()
fig.savefig(os.path.join(OUT, "baseline-bars.png"), facecolor=SURFACE,
            bbox_inches="tight")
plt.close(fig)
print("wrote baseline-bars.png")
