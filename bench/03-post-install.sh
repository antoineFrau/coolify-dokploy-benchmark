#!/usr/bin/env bash
# §5 -- platform installed, no applications yet. Run after a reboot + 5 min settle.
source "$(dirname "$(readlink -f "$0")")/lib.sh"

settle="${1:-300}"
info "$(platform): settling ${settle}s after reboot before measuring"
sleep "$settle"

snap post-install platform-idle --top 30 --cpu-window 5 --du >/dev/null
tail -1 "$RES/post-install.jsonl" | python3 -m json.tool
