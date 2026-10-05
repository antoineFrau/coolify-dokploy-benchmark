#!/usr/bin/env bash
# Shared helpers, guest side. Lives at /opt/bench on each VM.
set -euo pipefail

BENCH="${BENCH:-/opt/bench}"
RES="$BENCH/results"
PLATFORM_FILE="$BENCH/platform"
mkdir -p "$RES"

info() { echo "==> $*"; }
die()  { echo "error: $*" >&2; exit 1; }

platform() { cat "$PLATFORM_FILE" 2>/dev/null || echo unknown; }

# snap <phase> [label] [extra snapshot.py args...] -- append one observation to
# results/<phase>.jsonl and echo it.
snap() {
    local phase="$1" label="${2:-}"; shift 2 || true
    python3 "$BENCH/snapshot.py" --phase "$phase" --label "$label" "$@" \
        | tee -a "$RES/$phase.jsonl"
}

# monitor_start <phase> <interval-seconds> [extra args] -- background sampler.
monitor_start() {
    local phase="$1" interval="${2:-2}"; shift 2 || true
    local extra=("$@")
    # Fully detached, every fd closed: otherwise `ssh <vm> monitor_start` never
    # returns, because the sampler keeps the session's stdout open.
    setsid bash -c '
        phase="$1"; interval="$2"; res="$3"; bench="$4"; shift 4
        # setsid forks, so the sampler records its own pid -- $! on the caller side
        # would be the short-lived setsid process.
        echo $$ > "$res/$phase.monitor.pid"
        while :; do
            python3 "$bench/snapshot.py" --phase "$phase" --label monitor \
                --cpu-window 1 "$@" >> "$res/$phase.jsonl" 2>/dev/null || true
            sleep "$interval"
        done
    ' _ "$phase" "$interval" "$RES" "$BENCH" "${extra[@]}" \
        </dev/null >/dev/null 2>&1 &
    disown 2>/dev/null || true
    # Give the detached sampler a moment to publish its pid.
    for _ in 1 2 3 4 5; do [ -s "$RES/$phase.monitor.pid" ] && break; sleep 0.2; done
    info "monitor started for '$phase' (every ${interval}s)"
}

monitor_stop() {
    local phase="$1" pidfile="$RES/$1.monitor.pid"
    [ -f "$pidfile" ] || return 0
    local pid; pid="$(cat "$pidfile")"
    # setsid makes the sampler its own process-group leader, so kill the group.
    kill -- "-$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
    rm -f "$pidfile"
    info "monitor stopped for '$phase'"
}

# wait_marker <url> <marker> <timeout-s> -- poll until the deployed build answers
# with the expected BENCH_MARKER; this is how a deploy's end time is detected.
wait_marker() {
    local url="$1" marker="$2" timeout="${3:-1800}" start
    start=$(date +%s)
    while :; do
        if curl -fsS --max-time 5 "$url" 2>/dev/null | grep -q "$marker"; then
            return 0
        fi
        [ $(( $(date +%s) - start )) -lt "$timeout" ] || return 1
        sleep 2
    done
}

# wait_down <url> <timeout-s> -- poll until the endpoint stops answering, so a
# recovery time is measured against observed downtime rather than against a request
# that was served before the process actually died.
wait_down() {
    local url="$1" timeout="${2:-60}" start
    start=$(date +%s)
    while curl -fsS -o /dev/null --max-time 2 "$url" 2>/dev/null; do
        [ $(( $(date +%s) - start )) -lt "$timeout" ] || return 1
        sleep 0.5
    done
    return 0
}

now() { date +%s.%N; }
since() { python3 -c "import sys;print(f'{float(sys.argv[2])-float(sys.argv[1]):.1f}')" "$1" "$(now)"; }

write_summary() {  # write_summary <name> <json>
    echo "$2" > "$RES/$1.json"
    info "wrote $RES/$1.json"
    python3 -m json.tool "$RES/$1.json"
}
