#!/usr/bin/env bash
# stop-vm.sh <vm-name> [--force] -- clean ACPI shutdown (or kill) of a VM.
source "$(dirname "$(dirname "$(readlink -f "$0")")")/lib.sh"

name="${1:?usage: stop-vm.sh <vm-name> [--force]}"
pid="$(vm_pid "$name" || true)"
[ -n "$pid" ] || { info "$name is not running"; exit 0; }

if [ "${2:-}" = "--force" ]; then
    kill -9 "$pid"; info "$name killed"; exit 0
fi

info "$name: ACPI shutdown"
vm_ssh "$name" "sudo poweroff" 2>/dev/null || monitor_cmd "$name" system_powerdown || true

for _ in $(seq 60); do kill -0 "$pid" 2>/dev/null || { info "$name stopped"; exit 0; }; sleep 1; done
info "$name did not stop in 60s, killing"; kill -9 "$pid" 2>/dev/null || true
