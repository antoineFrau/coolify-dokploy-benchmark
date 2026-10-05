#!/usr/bin/env bash
# §4 -- Linux baseline. Run after a reboot of a VM that has no platform installed.
source "$(dirname "$(readlink -f "$0")")/lib.sh"

settle="${1:-120}"
up=$(cut -d. -f1 /proc/uptime)
if [ "$up" -gt 900 ]; then
    echo "warning: uptime is ${up}s -- the protocol wants a baseline shortly after reboot" >&2
fi

info "settling for ${settle}s after boot"
sleep "$settle"

info "baseline snapshot"
snap baseline post-boot --top 20 --cpu-window 5 --no-containers >/dev/null
tail -1 "$RES/baseline.jsonl" | python3 -m json.tool
