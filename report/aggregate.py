#!/usr/bin/env python3
"""Turn the collected measurements into the §18 comparison table and the §17
weighted score.

    report/aggregate.py [--results results] [--out results/report.md] [vm ...]

Every figure is read from the files the phase scripts wrote; nothing is inferred.
A metric that was never collected shows as "-" and is dropped from the score (with
its weight redistributed), so a partial run still produces an honest report rather
than a confident-looking one built on blanks.
"""
import argparse
import json
import os
import statistics
import sys

# §17 weights for an 8 GB / 50 GB target. Disk carries 35% in total because 50 GB
# is the binding constraint on the D2-8, not memory.
WEIGHTS = {
    "idle_ram": 0.20,
    "build_peak_ram": 0.15,
    "disk_usage": 0.20,
    "disk_growth": 0.15,
    "cpu_overhead": 0.10,
    "deploy_speed": 0.05,
    "reliability": 0.10,
    "usability": 0.05,
}

# True when a smaller number is the better outcome.
LOWER_IS_BETTER = {
    "idle_ram": True, "build_peak_ram": True, "disk_usage": True,
    "disk_growth": True, "cpu_overhead": True, "deploy_speed": True,
    "reliability": True, "usability": False,
}

MB = 1024 * 1024
GB = 1e9


# --------------------------------------------------------------------------- io

def read_jsonl(path):
    if not os.path.exists(path):
        return []
    rows = []
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if line:
                try:
                    rows.append(json.loads(line))
                except json.JSONDecodeError:
                    pass
    return rows


def read_json(path):
    if not os.path.exists(path):
        return None
    try:
        with open(path) as fh:
            return json.load(fh)
    except (json.JSONDecodeError, OSError):
        return None


# ---------------------------------------------------------------------- metrics

def collect(vm_dir):
    """Pull every figure the protocol asks for out of one VM's results."""
    m = {"vm": os.path.basename(vm_dir)}

    install = read_json(f"{vm_dir}/install.json") or {}
    m["platform"] = install.get("target", m["vm"])
    m["docker_version"] = install.get("docker_version")
    m["install_seconds"] = install.get("install_seconds")

    baseline = read_jsonl(f"{vm_dir}/baseline.jsonl")
    if baseline:
        b = baseline[-1]
        m["baseline_ram_mb"] = b["mem"]["used_mb"]
        m["baseline_disk_bytes"] = b["disk_root"]["used_bytes"]

    post = read_jsonl(f"{vm_dir}/post-install.jsonl")
    if post:
        p = post[-1]
        m["post_install_ram_mb"] = p["mem"]["used_mb"]
        m["post_install_available_mb"] = p["mem"]["available_mb"]
        m["post_install_cpu_busy"] = p["cpu"]["busy_pct"]
        m["post_install_disk_bytes"] = p["disk_root"]["used_bytes"]
        m["post_install_images_bytes"] = p["docker_df"].get("images", {}).get("size_bytes")
        m["post_install_volumes_bytes"] = p["docker_df"].get("local_volumes", {}).get("size_bytes")
        m["platform_container_ram_mb"] = round(p.get("container_mem_bytes", 0) / MB)
        if "baseline_ram_mb" in m:
            m["platform_ram_mb"] = m["post_install_ram_mb"] - m["baseline_ram_mb"]
        if "baseline_disk_bytes" in m:
            m["install_disk_bytes"] = m["post_install_disk_bytes"] - m["baseline_disk_bytes"]

    idle = read_jsonl(f"{vm_dir}/idle.jsonl")
    if idle:
        used = [r["mem"]["used_mb"] for r in idle]
        m["idle_ram_avg_mb"] = round(statistics.mean(used))
        m["idle_ram_min_mb"] = min(used)
        m["idle_ram_max_mb"] = max(used)
        m["idle_ram_drift_mb"] = used[-1] - used[0]
        m["idle_cpu_busy_pct"] = round(statistics.mean(r["cpu"]["busy_pct"] for r in idle), 2)
        m["idle_available_avg_mb"] = round(statistics.mean(r["mem"]["available_mb"] for r in idle))
        m["idle_samples"] = len(idle)

    long_idle = read_jsonl(f"{vm_dir}/long-idle.jsonl")
    if long_idle:
        used = [r["mem"]["used_mb"] for r in long_idle]
        m["long_idle_hours"] = round((long_idle[-1]["ts"] - long_idle[0]["ts"]) / 3600, 1)
        m["long_idle_ram_drift_mb"] = used[-1] - used[0]
        m["long_idle_disk_growth_bytes"] = (long_idle[-1]["disk_root"]["used_bytes"]
                                            - long_idle[0]["disk_root"]["used_bytes"])

    for mode in ("first", "cold", "warm"):
        d = read_json(f"{vm_dir}/deploy-{mode}.json")
        if not d:
            continue
        w = d.get("build_window", {})
        m[f"{mode}_build_seconds"] = d.get("duration_seconds")
        m[f"{mode}_build_status"] = d.get("status")
        m[f"{mode}_peak_ram_mb"] = w.get("ram_used_mb", {}).get("max")
        m[f"{mode}_min_available_mb"] = w.get("ram_available_mb", {}).get("min")
        m[f"{mode}_peak_cpu_pct"] = w.get("cpu_busy_pct", {}).get("max")
        m[f"{mode}_peak_load1"] = w.get("load1", {}).get("max")
        m[f"{mode}_disk_growth_bytes"] = w.get("disk_growth_bytes")
        m[f"{mode}_peak_swap_mb"] = w.get("swap_used_mb", {}).get("max")

    # Steady state with the app stack deployed: the last snapshot of the last deploy.
    for mode in ("warm", "cold", "first"):
        rows = [r for r in read_jsonl(f"{vm_dir}/deploy-{mode}.jsonl")
                if r.get("label") == "after"]
        if rows:
            r = rows[-1]
            m["with_app_ram_mb"] = r["mem"]["used_mb"]
            m["with_app_available_mb"] = r["mem"]["available_mb"]
            m["app_container_ram_mb"] = round(r.get("container_mem_bytes", 0) / MB)
            m["with_app_disk_bytes"] = r["disk_root"]["used_bytes"]
            per = {c["name"]: round(c["mem_bytes"] / MB) for c in r.get("containers", [])}
            m["container_ram_mb"] = per
            if "post_install_ram_mb" in m:
                # The number §8 actually asks for: platform + OS overhead.
                m["platform_plus_os_overhead_mb"] = r["mem"]["used_mb"] - m["app_container_ram_mb"]
            break

    disk = read_jsonl(f"{vm_dir}/disk-growth.jsonl")
    if disk:
        curve = {}
        for r in disk:
            label = r.get("label", "")
            if label.startswith("builds-"):
                curve[int(label.split("-")[1])] = {
                    "root_used_bytes": r["disk_root"]["used_bytes"],
                    "docker_storage_bytes": r.get("docker_dir_bytes"),
                    "images_bytes": r["docker_df"].get("images", {}).get("size_bytes"),
                    "build_cache_bytes": r["docker_df"].get("build_cache", {}).get("size_bytes"),
                    "volumes_bytes": r["docker_df"].get("local_volumes", {}).get("size_bytes"),
                }
        m["disk_curve"] = dict(sorted(curve.items()))
        if len(curve) >= 2:
            ks = sorted(curve)
            m["disk_growth_per_build_bytes"] = round(
                (curve[ks[-1]]["root_used_bytes"] - curve[ks[0]]["root_used_bytes"])
                / max(ks[-1] - ks[0], 1))
            m["disk_after_last_build_bytes"] = curve[ks[-1]]["root_used_bytes"]
            m["disk_builds_measured"] = ks[-1]

    pressure = read_jsonl(f"{vm_dir}/memory-pressure.jsonl")
    if pressure:
        steps = []
        for r in pressure:
            label = r.get("label", "")
            if label.startswith("apps-"):
                steps.append({"apps": int(label.split("-")[1]),
                              "available_mb": r["mem"]["available_mb"],
                              "used_mb": r["mem"]["used_mb"],
                              "swap_used_mb": r["swap"]["used_mb"]})
        steps.sort(key=lambda s: s["apps"])
        m["pressure_curve"] = steps
        comfortable = [s["apps"] for s in steps if s["available_mb"] > 2048]
        m["max_apps_above_2gb_free"] = max(comfortable) if comfortable else 0

    load = {}
    load_dir = f"{vm_dir}/load"
    if os.path.isdir(load_dir):
        for entry in sorted(os.listdir(load_dir)):
            if not entry.startswith("c"):
                continue
            summary = read_json(f"{load_dir}/{entry}/summary.json")
            if not summary:
                continue
            res = read_json(f"{load_dir}/{entry}/vm-resources.json") or {}
            load[int(entry[1:])] = {
                "rps": summary.get("rps"),
                "avg_ms": summary.get("latency_ms", {}).get("avg"),
                "p95_ms": summary.get("latency_ms", {}).get("p95"),
                "failed_ratio": summary.get("failed_ratio"),
                "vm_cpu_busy_max": res.get("cpu_busy_pct", {}).get("max"),
                "vm_ram_used_max_mb": res.get("ram_used_mb", {}).get("max"),
                "vm_load1_max": res.get("load1", {}).get("max"),
            }
    m["load"] = dict(sorted(load.items()))

    restart = read_json(f"{vm_dir}/restart.json")
    if restart:
        m["reboot_app_ready_s"] = restart.get("app_ready_seconds")
        m["reboot_dashboard_ready_s"] = restart.get("dashboard_ready_seconds")
        m["reboot_ram_mb"] = restart.get("ram_used_mb_after_reboot")
        m["reboot_failed_containers"] = restart.get("containers_not_running_after") or ""

    for mode in ("crash", "kill", "docker-restart"):
        f = read_json(f"{vm_dir}/failure-{mode}.json")
        if f:
            m[f"failure_{mode}"] = f.get("probe", {})

    m["manual"] = read_json(f"{vm_dir}/manual.json") or {}
    return m


# ---------------------------------------------------------------------- scoring

def score_inputs(m):
    """Map the raw measurements onto the §17 criteria (lower is better except UI)."""
    crash = m.get("failure_crash") or {}
    reliability = crash.get("http_downtime_s")
    if reliability is None:
        reliability = m.get("reboot_app_ready_s")

    return {
        "idle_ram": m.get("idle_ram_avg_mb", m.get("post_install_ram_mb")),
        "build_peak_ram": m.get("cold_peak_ram_mb", m.get("first_peak_ram_mb")),
        "disk_usage": (m.get("install_disk_bytes") or 0) / GB or None,
        "disk_growth": (m.get("disk_growth_per_build_bytes") or 0) / GB or None,
        "cpu_overhead": m.get("idle_cpu_busy_pct", m.get("post_install_cpu_busy")),
        "deploy_speed": m.get("warm_build_seconds", m.get("cold_build_seconds")),
        "reliability": reliability,
        "usability": m.get("manual", {}).get("usability_score"),
    }


def score(metrics):
    """Relative scoring: on each criterion the best platform gets 1.0 and the others
    are scaled against it. Weights of criteria nobody measured are redistributed, so
    the totals stay comparable and no blank silently counts as a zero."""
    inputs = {m["vm"]: score_inputs(m) for m in metrics}
    per_vm = {vm: {} for vm in inputs}
    used_weight = 0.0

    for crit, weight in WEIGHTS.items():
        vals = {vm: v[crit] for vm, v in inputs.items()
                if isinstance(v.get(crit), (int, float))}
        if len(vals) < 1:
            continue
        used_weight += weight
        if LOWER_IS_BETTER[crit]:
            best = min(v for v in vals.values() if v > 0) if any(v > 0 for v in vals.values()) else None
            for vm, v in vals.items():
                per_vm[vm][crit] = 1.0 if (best is None or v <= 0) else round(best / v, 3)
        else:
            best = max(vals.values())
            for vm, v in vals.items():
                per_vm[vm][crit] = round(v / best, 3) if best else 0.0

    totals = {}
    for vm, scores in per_vm.items():
        if not used_weight:
            totals[vm] = None
            continue
        got = sum(WEIGHTS[c] * s for c, s in scores.items())
        covered = sum(WEIGHTS[c] for c in scores)
        totals[vm] = round(100 * got / covered, 1) if covered else None

    return per_vm, totals, inputs, used_weight


# ----------------------------------------------------------------------- render

def fmt_bytes(v):
    if v is None:
        return "-"
    if abs(v) >= GB:
        return f"{v / GB:.2f} GB"
    if abs(v) >= 1e6:
        return f"{v / 1e6:.0f} MB"
    return f"{v} B"


def fmt(v, suffix="", digits=None):
    if v is None or v == "":
        return "-"
    if isinstance(v, float) and digits is not None:
        return f"{v:.{digits}f}{suffix}"
    return f"{v}{suffix}"


def table(headers, rows):
    out = ["| " + " | ".join(headers) + " |",
           "|" + "|".join(["---"] + ["---:"] * (len(headers) - 1)) + "|"]
    out += ["| " + " | ".join(str(c) for c in row) + " |" for row in rows]
    return "\n".join(out) + "\n"


def render(metrics, per_vm, totals, inputs):
    vms = [m["vm"] for m in metrics]
    by_vm = {m["vm"]: m for m in metrics}
    head = ["Measurement"] + [f"{by_vm[v].get('platform', v)} ({v})" for v in vms]

    def row(label, key, formatter=fmt, **kw):
        return [label] + [formatter(by_vm[v].get(key), **kw) for v in vms]

    out = ["# Coolify vs Dokploy — benchmark results\n",
           "Target: 4 vCPU / 8 GB / 50 GB (OVH D2-8 class). "
           "Every figure below comes from a file under `results/`; `-` means that "
           "measurement was not collected.\n",
           "## §18 Final comparison\n"]

    out.append(table(head, [
        row("OS baseline RAM used", "baseline_ram_mb", fmt, suffix=" MB"),
        row("Platform idle RAM (over baseline)", "platform_ram_mb", fmt, suffix=" MB"),
        row("Total idle RAM used", "idle_ram_avg_mb", fmt, suffix=" MB"),
        row("Idle RAM drift over the window", "idle_ram_drift_mb", fmt, suffix=" MB"),
        row("Idle available RAM", "idle_available_avg_mb", fmt, suffix=" MB"),
        row("Idle CPU busy", "idle_cpu_busy_pct", fmt, suffix=" %"),
        row("Installation disk", "install_disk_bytes", fmt_bytes),
        row("Docker images after install", "post_install_images_bytes", fmt_bytes),
        row("Cold build time", "cold_build_seconds", fmt, suffix=" s"),
        row("Cold build peak RAM", "cold_peak_ram_mb", fmt, suffix=" MB"),
        row("Cold build min available RAM", "cold_min_available_mb", fmt, suffix=" MB"),
        row("Cold build peak CPU", "cold_peak_cpu_pct", fmt, suffix=" %"),
        row("Cold build peak load", "cold_peak_load1", fmt),
        row("Warm build time", "warm_build_seconds", fmt, suffix=" s"),
        row("Disk growth per build", "disk_growth_per_build_bytes", fmt_bytes),
        row("Disk after last measured build", "disk_after_last_build_bytes", fmt_bytes),
        row("RAM with the app stack running", "with_app_ram_mb", fmt, suffix=" MB"),
        row("App containers RAM", "app_container_ram_mb", fmt, suffix=" MB"),
        row("Platform + OS overhead", "platform_plus_os_overhead_mb", fmt, suffix=" MB"),
        row("Max apps with >2 GB free", "max_apps_above_2gb_free", fmt),
        row("Reboot: app ready", "reboot_app_ready_s", fmt, suffix=" s"),
        row("Reboot: dashboard ready", "reboot_dashboard_ready_s", fmt, suffix=" s"),
        row("Failed containers after reboot", "reboot_failed_containers", fmt),
    ]))

    # §11 -- one block per concurrency level actually run.
    levels = sorted({c for m in metrics for c in m.get("load", {})})
    if levels:
        out.append("\n## §11 Load test\n")
        rows = []
        for c in levels:
            for key, label, digits in (("rps", "requests/sec", 0),
                                       ("avg_ms", "avg latency (ms)", 2),
                                       ("p95_ms", "p95 latency (ms)", 2),
                                       ("vm_cpu_busy_max", "peak VM CPU (%)", 1),
                                       ("vm_ram_used_max_mb", "peak VM RAM (MB)", 0)):
                rows.append([f"c={c} {label}"] + [
                    fmt(by_vm[v].get("load", {}).get(c, {}).get(key), digits=digits)
                    for v in vms])
        out.append(table(["Measurement"] + head[1:], rows))
        out.append("\n> Load is generated on the host through QEMU user-mode "
                   "networking, which caps absolute throughput. Both VMs are measured "
                   "through the identical path, so the comparison holds; read the "
                   "absolute rps as a floor, not as the D2-8's capacity.\n")

    # §13 -- the disk curve, which carries 35% of the score.
    builds = sorted({b for m in metrics for b in m.get("disk_curve", {})})
    if builds:
        out.append("\n## §13 Disk growth\n")
        rows = []
        for b in builds:
            rows.append([f"after {b} build(s) — root used"] +
                        [fmt_bytes(by_vm[v].get("disk_curve", {}).get(b, {}).get("root_used_bytes"))
                         for v in vms])
            rows.append([f"after {b} build(s) — build cache"] +
                        [fmt_bytes(by_vm[v].get("disk_curve", {}).get(b, {}).get("build_cache_bytes"))
                         for v in vms])
        out.append(table(["Measurement"] + head[1:], rows))

    # §12 -- how many apps fit.
    apps = sorted({s["apps"] for m in metrics for s in m.get("pressure_curve", [])})
    if apps:
        out.append("\n## §12 Memory pressure\n")
        rows = []
        for a in apps:
            cells = []
            for v in vms:
                step = next((s for s in by_vm[v].get("pressure_curve", [])
                             if s["apps"] == a), None)
                cells.append(f"{step['available_mb']} MB" if step else "-")
            rows.append([f"{a} app(s) — available RAM"] + cells)
        out.append(table(["Measurement"] + head[1:], rows))
        out.append("\n> Thresholds from §12: >2 GB comfortable, 1–2 GB acceptable, "
                   "500 MB–1 GB risky, <500 MB too close to the limit.\n")

    # §15 -- recovery.
    if any(m.get("failure_crash") for m in metrics):
        out.append("\n## §15 Failure recovery\n")
        def fail(key, digits=2):
            return [fmt((by_vm[v].get("failure_crash") or {}).get(key), digits=digits)
                    for v in vms]
        out.append(table(["Measurement"] + head[1:], [
            ["HTTP downtime (s)"] + fail("http_downtime_s"),
            ["Container restarted"] + [str((by_vm[v].get("failure_crash") or {})
                                           .get("container_restarted", "-")) for v in vms],
            ["Container recovery (s)"] + fail("container_recovery_s"),
        ]))

    # §17 -- weighted score.
    out.append("\n## §17 Weighted score\n")
    rows = []
    for crit, weight in WEIGHTS.items():
        rows.append([f"{crit.replace('_', ' ')} ({weight:.0%})"] +
                    [fmt(inputs[v].get(crit), digits=2) for v in vms] +
                    [fmt(per_vm[v].get(crit), digits=3) for v in vms])
    out.append(table(["Criterion"] + [f"{v} value" for v in vms] +
                     [f"{v} score" for v in vms], rows))
    out.append("\n" + table(["Total (0–100)"] + vms,
                            [["weighted"] + [fmt(totals[v], digits=1) for v in vms]]))
    out.append("\n> Scores are relative: on each criterion the best platform scores "
               "1.0 and the other is scaled against it. Criteria with no measurement "
               "are excluded and their weight redistributed. `usability` is manual — "
               "put a 0–10 value in `results/<vm>/manual.json` as "
               '`{"usability_score": 7}` to include it.\n')

    missing = [c for c in WEIGHTS if not any(isinstance(inputs[v].get(c), (int, float))
                                             for v in vms)]
    if missing:
        out.append(f"\n**Not yet measured:** {', '.join(sorted(missing))}\n")

    return "\n".join(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("vms", nargs="*", help="result directory names (default: all)")
    ap.add_argument("--results", default="results")
    ap.add_argument("--out", default=None)
    ap.add_argument("--json", action="store_true", help="dump raw metrics instead")
    args = ap.parse_args()

    names = args.vms or sorted(
        d for d in os.listdir(args.results)
        if os.path.isdir(os.path.join(args.results, d)))
    if not names:
        print(f"no result directories under {args.results}", file=sys.stderr)
        return 1

    metrics = [collect(os.path.join(args.results, n)) for n in names]
    if args.json:
        print(json.dumps(metrics, indent=2))
        return 0

    per_vm, totals, inputs, _ = score(metrics)
    report = render(metrics, per_vm, totals, inputs)
    out = args.out or os.path.join(args.results, "report.md")
    with open(out, "w") as fh:
        fh.write(report)
    print(report)
    print(f"\n(written to {out})", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
