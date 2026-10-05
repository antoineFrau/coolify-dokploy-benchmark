#!/usr/bin/env bash
# destroy-vm.sh <vm-name> -- stop the VM and delete its disk. Results under results/ are kept.
source "$(dirname "$(dirname "$(readlink -f "$0")")")/lib.sh"

name="${1:?usage: destroy-vm.sh <vm-name>}"
"$ROOT/vm/stop-vm.sh" "$name" --force >/dev/null 2>&1 || true
rm -rf "$(vm_dir "$name")"
info "$name destroyed (results/ untouched)"
