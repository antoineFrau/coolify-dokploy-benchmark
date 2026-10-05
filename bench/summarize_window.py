#!/usr/bin/env python3
"""Reduce a window of snapshots to the figures the protocol asks to record:
peak RAM, minimum available RAM, peak CPU, peak load average, and disk growth.

    summarize_window.py <jsonl> [--from TS] [--to TS]
"""
import argparse
import json
import sys


def load(path, lo, hi):
    rows = []
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue
            if lo is not None and row["ts"] < lo:
                continue
            if hi is not None and row["ts"] > hi:
                continue
            rows.append(row)
    return rows


def summarize(rows):
    if not rows:
        return {"samples": 0}
    used = [r["mem"]["used_mb"] for r in rows]
    avail = [r["mem"]["available_mb"] for r in rows]
    busy = [r["cpu"]["busy_pct"] for r in rows]
    load1 = [r["load"][0] for r in rows]
    disk = [r["disk_root"]["used_bytes"] for r in rows]
    swap = [r["swap"]["used_mb"] for r in rows]
    cmem = [r.get("container_mem_bytes", 0) for r in rows]

    def stats(xs):
        return {"min": min(xs), "max": max(xs),
                "avg": round(sum(xs) / len(xs), 2), "last": xs[-1]}

    return {
        "samples": len(rows),
        "window_s": round(rows[-1]["ts"] - rows[0]["ts"], 1),
        "ram_used_mb": stats(used),
        "ram_available_mb": stats(avail),
        "swap_used_mb": stats(swap),
        "cpu_busy_pct": stats(busy),
        "load1": stats(load1),
        "container_mem_bytes": stats(cmem),
        "disk_used_bytes": stats(disk),
        "disk_growth_bytes": disk[-1] - disk[0],
        # A control plane that leaks shows up as used RAM climbing across the window.
        "ram_drift_mb": used[-1] - used[0],
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("jsonl")
    ap.add_argument("--from", dest="lo", type=float, default=None)
    ap.add_argument("--to", dest="hi", type=float, default=None)
    args = ap.parse_args()
    print(json.dumps(summarize(load(args.jsonl, args.lo, args.hi)), indent=2))


if __name__ == "__main__":
    sys.exit(main())
