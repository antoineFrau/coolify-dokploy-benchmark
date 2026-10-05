#!/usr/bin/env python3
"""§15 -- trigger a failure and measure how long the app is actually unavailable.

Two independent clocks, because they answer different questions:

  * HTTP downtime -- what a user would notice. Probed continuously at ~20 Hz,
    because a container restart can be under a second and a 2 s polling loop
    reports "no downtime" for an outage that really happened.
  * Container recovery -- what the platform did. Taken from Docker's own
    RestartCount and StartedAt, which cannot be missed by sampling.

Usage:
    failure_probe.py <url> <marker> <container> --mode crash|kill|docker-restart
                     [--crash-url URL] [--timeout 600]
"""
import argparse
import datetime
import json
import subprocess
import threading
import time
import urllib.error
import urllib.request

PROBE_INTERVAL = 0.05
RECOVERED_STREAK = 5  # consecutive good probes before we call it recovered


def parse_docker_time(stamp):
    """Docker timestamps are UTC with nanosecond precision, which datetime cannot
    parse directly; trim to microseconds and keep the sub-second resolution that
    makes a one-second restart measurable."""
    try:
        head, _, frac = stamp.partition(".")
        micros = (frac.rstrip("Z") + "000000")[:6] if frac else "000000"
        parsed = datetime.datetime.strptime(head, "%Y-%m-%dT%H:%M:%S").replace(
            tzinfo=datetime.timezone.utc, microsecond=int(micros))
        return parsed.timestamp()
    except (ValueError, TypeError):
        return None


def inspect(container):
    out = subprocess.run(
        ["docker", "inspect", "--format",
         "{{.State.Status}}|{{.RestartCount}}|{{.State.StartedAt}}|{{.State.ExitCode}}",
         container],
        capture_output=True, text=True)
    if out.returncode != 0:
        return None
    status, restarts, started, exit_code = out.stdout.strip().split("|")
    return {"status": status, "restarts": int(restarts), "started_at": started,
            "exit_code": int(exit_code)}


class Probe(threading.Thread):
    """Hammers the URL and records every transition between up and down."""

    def __init__(self, url, marker):
        super().__init__(daemon=True)
        self.url, self.marker = url, marker
        self.stop_flag = threading.Event()
        self.events = []       # (timestamp, up?)
        self.last_up = None
        self.streak = 0

    def ok(self):
        try:
            with urllib.request.urlopen(self.url, timeout=2) as r:
                return r.status == 200 and self.marker in r.read().decode("utf-8", "replace")
        except (urllib.error.URLError, OSError, ValueError):
            return False

    def run(self):
        while not self.stop_flag.is_set():
            up = self.ok()
            now = time.time()
            if up != self.last_up:
                self.events.append((now, up))
                self.last_up = up
            self.streak = self.streak + 1 if up else 0
            time.sleep(PROBE_INTERVAL)

    def recovered(self):
        return self.streak >= RECOVERED_STREAK


def trigger(mode, container, crash_url):
    if mode == "crash":
        try:
            urllib.request.urlopen(crash_url, timeout=5).read()
        except Exception:
            pass  # the handler kills the process; a broken response is expected
    elif mode == "kill":
        subprocess.run(["docker", "kill", container], capture_output=True)
    elif mode == "docker-restart":
        subprocess.run(["sudo", "systemctl", "restart", "docker"], capture_output=True)
    else:
        raise SystemExit(f"unknown mode {mode}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("url"); ap.add_argument("marker"); ap.add_argument("container")
    ap.add_argument("--mode", default="crash",
                    choices=["crash", "kill", "docker-restart"])
    ap.add_argument("--crash-url", default=None)
    ap.add_argument("--timeout", type=float, default=600)
    args = ap.parse_args()

    crash_url = args.crash_url or args.url.rsplit("/api/", 1)[0] + "/api/crash"
    before = inspect(args.container)

    probe = Probe(args.url, args.marker)
    probe.start()
    time.sleep(1)  # establish that it is up before we break it
    if probe.last_up is not True:
        print(json.dumps({"error": "app was not serving the marker before the test",
                          "url": args.url, "marker": args.marker}, indent=2))
        return 1

    t0 = time.time()
    trigger(args.mode, args.container, crash_url)

    deadline = t0 + args.timeout
    no_downtime_grace = t0 + 15  # if nothing ever broke, do not wait out the timeout
    while time.time() < deadline:
        went_down = any(not up for ts, up in probe.events if ts >= t0)
        if went_down and probe.recovered():
            break
        if not went_down and time.time() > no_downtime_grace:
            break
        time.sleep(0.1)

    time.sleep(1)
    probe.stop_flag.set()
    probe.join(timeout=5)

    after = inspect(args.container)
    downs = [ts for ts, up in probe.events if not up and ts >= t0]
    ups = [ts for ts, up in probe.events if up and ts >= t0]
    first_down = min(downs) if downs else None
    first_up = min(u for u in ups if first_down and u > first_down) if (downs and ups) else None

    container_recovery = None
    if before and after and after["restarts"] > before["restarts"]:
        started = parse_docker_time(after["started_at"])
        if started is not None:
            container_recovery = round(started - t0, 2)

    result = {
        "mode": args.mode,
        "container": args.container,
        "http_went_down": first_down is not None,
        "http_down_after_s": round(first_down - t0, 2) if first_down else None,
        "http_downtime_s": round(first_up - first_down, 2) if (first_down and first_up) else None,
        "http_recovered": bool(first_up) or (first_down is None and probe.recovered()),
        "container_restarted": bool(before and after and after["restarts"] > before["restarts"]),
        "container_restart_count_before": before["restarts"] if before else None,
        "container_restart_count_after": after["restarts"] if after else None,
        "container_recovery_s": container_recovery,
        "container_status_after": after["status"] if after else "missing",
        "container_exit_code": after["exit_code"] if after else None,
        "probe_interval_s": PROBE_INTERVAL,
    }
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
