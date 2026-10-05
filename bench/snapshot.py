#!/usr/bin/env python3
"""One benchmark observation, emitted as a single JSON line.

Everything the protocol asks to "record" at a point in time is captured here so
that every phase produces the same shape and report/aggregate.py can read all of
it uniformly: memory (§4, §18 -- free -m is the figure that matters), CPU idle,
load average, root-filesystem usage, Docker's own accounting (§13) and per
container memory/CPU (§5, §8).
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import time

MIB = 1024 * 1024


def run(cmd, timeout=60):
    try:
        out = subprocess.run(cmd, shell=True, capture_output=True, text=True,
                             timeout=timeout)
        return out.stdout if out.returncode == 0 else ""
    except subprocess.TimeoutExpired:
        return ""


def docker_cmd():
    """Platform installers do not all add the login user to the docker group
    (Coolify's does not), and a snapshot that silently cannot reach the daemon
    reports zero containers and zero image size. Fall back to passwordless sudo
    rather than record a blank."""
    probe = subprocess.run("docker ps -q", shell=True, capture_output=True,
                           text=True, timeout=30)
    if probe.returncode == 0:
        return "docker"
    probe = subprocess.run("sudo -n docker ps -q", shell=True, capture_output=True,
                           text=True, timeout=30)
    return "sudo -n docker" if probe.returncode == 0 else "docker"


DOCKER = None


def meminfo():
    vals = {}
    with open("/proc/meminfo") as fh:
        for line in fh:
            k, _, rest = line.partition(":")
            vals[k] = int(rest.split()[0]) // 1024  # MiB
    total, avail, free = vals["MemTotal"], vals["MemAvailable"], vals["MemFree"]
    buffcache = vals["Buffers"] + vals["Cached"] + vals.get("SReclaimable", 0)
    return {
        "mem": {
            "total_mb": total,
            "used_mb": total - free - buffcache,
            "free_mb": free,
            "shared_mb": vals.get("Shmem", 0),
            "buffcache_mb": buffcache,
            "available_mb": avail,
        },
        "swap": {
            "total_mb": vals["SwapTotal"],
            "used_mb": vals["SwapTotal"] - vals["SwapFree"],
        },
    }


def cpu_sample(window):
    """CPU idle percentage over `window` seconds, from /proc/stat deltas."""
    def read():
        with open("/proc/stat") as fh:
            parts = [int(x) for x in fh.readline().split()[1:]]
        return sum(parts), parts[3] + parts[4]  # total, idle+iowait

    t0, i0 = read()
    time.sleep(window)
    t1, i1 = read()
    dt = t1 - t0
    idle = 100.0 * (i1 - i0) / dt if dt else 0.0
    return {"idle_pct": round(idle, 2), "busy_pct": round(100 - idle, 2),
            "window_s": window}


def loadavg():
    with open("/proc/loadavg") as fh:
        a, b, c = fh.readline().split()[:3]
    return [float(a), float(b), float(c)]


def disk_root():
    st = shutil.disk_usage("/")
    return {"total_bytes": st.total, "used_bytes": st.used,
            "free_bytes": st.free,
            "used_pct": round(100 * st.used / st.total, 2)}


_SIZE = re.compile(r"^([\d.]+)\s*([KMGT]?i?B?)$", re.I)
_MULT = {"": 1, "B": 1, "KB": 1e3, "MB": 1e6, "GB": 1e9, "TB": 1e12,
         "KIB": 1024, "MIB": 1024 ** 2, "GIB": 1024 ** 3, "TIB": 1024 ** 4}


def parse_size(text):
    """Docker prints human sizes ('1.234GB', '512MiB'); normalise to bytes."""
    if not text:
        return 0
    m = _SIZE.match(text.strip())
    if not m:
        return 0
    return int(float(m.group(1)) * _MULT.get(m.group(2).upper(), 1))


def docker_df():
    # Not an f-string: the Go template braces must survive verbatim.
    out = run(DOCKER + " system df --format"
              " '{{.Type}}|{{.TotalCount}}|{{.Active}}|{{.Size}}|{{.Reclaimable}}'")
    rows = {}
    for line in out.strip().splitlines():
        parts = line.split("|")
        if len(parts) != 5:
            continue
        kind, count, active, size, reclaim = parts
        rows[kind.strip().lower().replace(" ", "_")] = {
            "count": int(count) if count.isdigit() else None,
            "active": int(active) if active.isdigit() else None,
            "size_bytes": parse_size(size),
            "reclaimable_bytes": parse_size(reclaim.split("(")[0]),
        }
    return rows


def containers():
    fmt = '{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}|{{.MemPerc}}|{{.NetIO}}|{{.BlockIO}}|{{.PIDs}}'
    out = run(DOCKER + f" stats --no-stream --format '{fmt}'", timeout=120)
    result = []
    for line in out.strip().splitlines():
        parts = line.split("|")
        if len(parts) != 7:
            continue
        name, cpu, mem, memp, net, blk, pids = parts
        used, _, limit = mem.partition("/")
        result.append({
            "name": name.strip(),
            "cpu_pct": float(cpu.strip().rstrip("%") or 0),
            "mem_bytes": parse_size(used),
            "mem_limit_bytes": parse_size(limit),
            "mem_pct": float(memp.strip().rstrip("%") or 0),
            "net_io": net.strip(),
            "block_io": blk.strip(),
            "pids": int(pids.strip() or 0),
        })
    return sorted(result, key=lambda c: -c["mem_bytes"])


def docker_storage_bytes():
    """Authoritative on-disk size (§13).

    Docker 29 defaults to the containerd snapshotter, so most image and layer data
    sits under /var/lib/containerd, not /var/lib/docker -- measuring only the latter
    undercounts by several GB. Both are reported, plus their sum. Needs root, so it
    is opt-in: `du` over a large tree is slow enough to perturb a sampling loop.

    Treat these as a breakdown, not as the total: on the classic overlay2 driver
    `du` double-counts layer content that appears under several directories and can
    exceed the filesystem's own used figure. `disk_root.used_bytes` (df) is the
    authoritative answer to how much of the 50 GB is gone.
    """
    sizes = {}
    for key, path in (("docker", "/var/lib/docker"),
                      ("containerd", "/var/lib/containerd")):
        out = run(f"sudo du -sb {path} 2>/dev/null", timeout=900)
        try:
            sizes[key] = int(out.split()[0])
        except (IndexError, ValueError):
            sizes[key] = 0
    sizes["total"] = sizes["docker"] + sizes["containerd"]
    return sizes


def top_processes(n):
    out = run(f"ps axo rss,pcpu,comm --sort=-rss --no-headers | head -{n}")
    procs = []
    for line in out.strip().splitlines():
        parts = line.split(None, 2)
        if len(parts) == 3:
            procs.append({"rss_mb": int(parts[0]) // 1024,
                          "cpu_pct": float(parts[1]), "comm": parts[2].strip()})
    return procs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--phase", default="unknown")
    ap.add_argument("--label", default="")
    ap.add_argument("--cpu-window", type=float, default=2.0)
    ap.add_argument("--du", action="store_true",
                    help="include du -sb /var/lib/docker (slow, needs sudo)")
    ap.add_argument("--no-containers", action="store_true")
    ap.add_argument("--top", type=int, default=0, help="include top N processes by RSS")
    args = ap.parse_args()

    global DOCKER
    DOCKER = docker_cmd()

    snap = {
        "ts": time.time(),
        "iso": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "host": os.uname().nodename,
        "phase": args.phase,
        "label": args.label,
        "uptime_s": float(open("/proc/uptime").read().split()[0]),
        **meminfo(),
        "cpu": cpu_sample(args.cpu_window),
        "load": loadavg(),
        "disk_root": disk_root(),
        "docker_df": docker_df(),
    }
    if not args.no_containers:
        snap["containers"] = containers()
        snap["container_mem_bytes"] = sum(c["mem_bytes"] for c in snap["containers"])
        snap["container_cpu_pct"] = round(
            sum(c["cpu_pct"] for c in snap["containers"]), 2)
    if args.du:
        snap["docker_storage"] = docker_storage_bytes()
        snap["docker_dir_bytes"] = snap["docker_storage"]["total"]
    if args.top:
        snap["top_processes"] = top_processes(args.top)

    print(json.dumps(snap))


if __name__ == "__main__":
    main()
