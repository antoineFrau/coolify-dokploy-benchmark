#!/usr/bin/env bash
# §6 -- idle consumption over time (default 30 minutes, one sample a minute).
# Looks for a control plane that grows while doing nothing.
source "$(dirname "$(readlink -f "$0")")/lib.sh"

minutes="${1:-30}"
interval="${2:-60}"
phase="${3:-idle}"
info "$(platform): sampling idle for ${minutes} min every ${interval}s -- do not touch the dashboard"

end=$(( $(date +%s) + minutes * 60 ))
n=0
while [ "$(date +%s)" -lt "$end" ]; do
    snap "$phase" "minute-$n" --cpu-window 5 >/dev/null
    n=$(( n + 1 ))
    printf '    sample %d/%d\n' "$n" "$(( minutes * 60 / interval ))"
    sleep "$interval"
done
info "collected $n samples in $RES/$phase.jsonl"
python3 "$BENCH/summarize_window.py" "$RES/$phase.jsonl"
