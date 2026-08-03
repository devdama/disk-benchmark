#!/usr/bin/env python3
"""
generate.py
-----------
Regenerate every chart used in the SSD RAID benchmark blog series
directly from the raw CSVs, so the images are always reproducible
from the source of truth.

Inputs  : results/windows/*.csv , results/linux/*.csv
          (as written by Run-DiskBenchmark.ps1 / run-disk-benchmark.sh)
Outputs : resources/*.png  (charts embedded by the blog HTML)

Usage   : python3 generate.py
          python3 generate.py --results ./results --out ./resources

Only depends on the standard library + matplotlib:
    pip install matplotlib
"""

import argparse
import csv
import glob
import os
import sys
from collections import defaultdict

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

# ---- Fixed vocabulary (matches both benchmark scripts) --------------
CONFIGS = ["NonRAID", "RAID0", "RAID1"]
CONFIG_COLORS = {"NonRAID": "#6c757d", "RAID0": "#e8590c", "RAID1": "#1c7ed6"}
OS_COLORS = {"windows": "#1c7ed6", "linux": "#e8590c"}
OS_LABELS = {"windows": "Windows", "linux": "Linux (WSL)"}

SEQ_R, SEQ_W = "SEQ1M-Q8T1-Read", "SEQ1M-Q8T1-Write"
R32_R, R32_W = "RND4K-Q32T16-Read", "RND4K-Q32T16-Write"
R1_R, R1_W = "RND4K-Q1T1-Read", "RND4K-Q1T1-Write"
ALL_TESTS = [SEQ_R, SEQ_W, R32_R, R32_W, R1_R, R1_W]


# ---- Load + aggregate ------------------------------------------------
def load_platform(results_dir, platform):
    """
    Read every CSV under results/<platform>/ and return:
        data[config][test] = {"mbps":x, "iops":y, "lat":z}
    averaged across drives AND iterations.
    Returns None if no CSVs are found for the platform.
    """
    pattern = os.path.join(results_dir, platform, "*.csv")
    files = sorted(glob.glob(pattern))
    if not files:
        return None

    # acc[config][test][metric] -> list of values to average
    acc = defaultdict(lambda: defaultdict(lambda: defaultdict(list)))
    for path in files:
        with open(path, newline="", encoding="utf-8-sig") as fh:
            for row in csv.DictReader(fh):
                cfg, test = row.get("Config"), row.get("Test")
                if cfg not in CONFIGS or test not in ALL_TESTS:
                    continue
                try:
                    acc[cfg][test]["mbps"].append(float(row["MBps"]))
                    acc[cfg][test]["iops"].append(float(row["IOPS"]))
                    acc[cfg][test]["lat"].append(float(row["AvgLat_ms"]))
                except (KeyError, ValueError):
                    continue

    data = {}
    for cfg, tests in acc.items():
        data[cfg] = {}
        for test, metrics in tests.items():
            data[cfg][test] = {m: sum(v) / len(v) for m, v in metrics.items()}
    return data


def metric(data, test, key):
    """Safe lookup; returns 0.0 if a config/test is missing."""
    return data.get(test, {}).get(key, 0.0) if data else 0.0


# ---- Generic grouped-bar chart (one platform, by config) ------------
def chart_by_config(series, title, ylabel, out_path, fmt):
    """series: dict[label] -> dict[config] -> value"""
    labels = list(series)
    x = np.arange(len(labels))
    w = 0.26
    fig, ax = plt.subplots(figsize=(9, 4.8))
    for i, cfg in enumerate(CONFIGS):
        vals = [series[l].get(cfg, 0.0) for l in labels]
        bars = ax.bar(x + (i - 1) * w, vals, w, label=cfg, color=CONFIG_COLORS[cfg])
        for b, v in zip(bars, vals):
            ax.text(b.get_x() + b.get_width() / 2, v, fmt.format(v),
                    ha="center", va="bottom", fontsize=7.5)
    ax.set_xticks(x)
    ax.set_xticklabels(labels, fontsize=8.5)
    ax.set_ylabel(ylabel)
    ax.set_title(title, fontweight="bold")
    ax.legend()
    ax.grid(axis="y", alpha=0.3)
    ax.set_axisbelow(True)
    ax.margins(y=0.15)
    fig.tight_layout()
    fig.savefig(out_path, dpi=110)
    plt.close()
    print("wrote", out_path)


# ---- Windows-vs-Linux comparison chart ------------------------------
def chart_compare(win, lin, key, title, ylabel, out_path, fmt):
    labels, wv, lv = [], [], []
    for cfg in CONFIGS:
        for test, rw in ((f"SEQ/{cfg}", None),):  # placeholder, replaced below
            pass
    # Build Read/Write pairs per config for the given metric key
    pairs = [(SEQ_R, "Read"), (SEQ_W, "Write")] if key == "mbps" else [(R32_R, "Read"), (R32_W, "Write")]
    for cfg in CONFIGS:
        for test, rw in pairs:
            labels.append(f"{cfg}\n{rw}")
            wv.append(metric(win.get(cfg, {}), test, key) if win else 0.0)
            lv.append(metric(lin.get(cfg, {}), test, key) if lin else 0.0)
    x = np.arange(len(labels))
    w = 0.38
    fig, ax = plt.subplots(figsize=(10, 4.8))
    b1 = ax.bar(x - w / 2, wv, w, label=OS_LABELS["windows"], color=OS_COLORS["windows"])
    b2 = ax.bar(x + w / 2, lv, w, label=OS_LABELS["linux"], color=OS_COLORS["linux"])
    for bars in (b1, b2):
        for b in bars:
            ax.text(b.get_x() + b.get_width() / 2, b.get_height(), fmt.format(b.get_height()),
                    ha="center", va="bottom", fontsize=7)
    ax.set_xticks(x)
    ax.set_xticklabels(labels, fontsize=8)
    ax.set_ylabel(ylabel)
    ax.set_title(title, fontweight="bold")
    ax.legend()
    ax.grid(axis="y", alpha=0.3)
    ax.set_axisbelow(True)
    ax.margins(y=0.16)
    fig.tight_layout()
    fig.savefig(out_path, dpi=110)
    plt.close()
    print("wrote", out_path)


# ---- Per-platform chart set (throughput / IOPS / latency) -----------
def build_platform_charts(data, out_dir, prefix, title_prefix):
    # Throughput: all six tests
    thr = {t: {c: metric(data.get(c, {}), t, "mbps") for c in CONFIGS} for t in ALL_TESTS}
    chart_by_config(thr, f"{title_prefix}Throughput (MB/s)", "MB/s",
                    os.path.join(out_dir, f"{prefix}throughput.png"), "{:.0f}")

    # IOPS: random tests only (sequential IOPS are tiny and mix scales badly)
    iops = {t: {c: metric(data.get(c, {}), t, "iops") for c in CONFIGS}
            for t in (R32_R, R32_W, R1_R, R1_W)}
    chart_by_config(iops, f"{title_prefix}Random 4K IOPS", "IOPS",
                    os.path.join(out_dir, f"{prefix}iops.png"), "{:.0f}")

    # Latency: responsiveness-sensitive cases (SEQ + QD1); high-QD is omitted
    lat_map = {"SEQ1M Read": SEQ_R, "SEQ1M Write": SEQ_W,
               "RND4K QD1 Read": R1_R, "RND4K QD1 Write": R1_W}
    lat = {label: {c: metric(data.get(c, {}), t, "lat") for c in CONFIGS}
           for label, t in lat_map.items()}
    chart_by_config(lat, f"{title_prefix}Average latency (ms, lower=better)", "ms",
                    os.path.join(out_dir, f"{prefix}latency.png"), "{:.2f}")


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser(description="Regenerate blog charts from benchmark CSVs.")
    ap.add_argument("--results", default=os.path.join(here, "results"),
                    help="results/ folder containing windows/ and linux/ subfolders")
    ap.add_argument("--out", default=os.path.join(here, "resources"),
                    help="output folder for PNG charts")
    args = ap.parse_args()

    os.makedirs(args.out, exist_ok=True)
    win = load_platform(args.results, "windows")
    lin = load_platform(args.results, "linux")

    if win is None and lin is None:
        sys.exit(f"No CSVs found under {args.results}/(windows|linux)/")

    # Part 1 — Windows charts (chart_*.png)
    if win:
        build_platform_charts(win, args.out, "chart_", "")
    else:
        print("note: no Windows CSVs; skipping Windows charts")

    # Part 2 — Linux charts (lin_chart_*.png)
    if lin:
        build_platform_charts(lin, args.out, "lin_chart_", "Linux (WSL Ubuntu / fio): ")
    else:
        print("note: no Linux CSVs; skipping Linux charts")

    # Cross-platform comparison (cmp_*.png) — needs both
    if win and lin:
        chart_compare(win, lin, "mbps",
                      "Sequential throughput: Windows vs Linux (WSL)", "MB/s",
                      os.path.join(args.out, "cmp_seq.png"), "{:.0f}")
        chart_compare(win, lin, "iops",
                      "Random 4K QD32 IOPS: Windows vs Linux (WSL)", "IOPS",
                      os.path.join(args.out, "cmp_iops.png"), "{:.0f}")
    else:
        print("note: need both platforms for comparison charts; skipping cmp_*")

    print("Done.")


if __name__ == "__main__":
    main()
