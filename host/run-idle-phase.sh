#!/usr/bin/env bash
# run-idle-phase.sh <vm-name> [platform] [idle-minutes]
#
# The unattended part of the protocol: everything from a fresh VM up to and
# including the §6 idle measurement, with no application deployed.
#
#   §4  fresh-Ubuntu baseline (reboot, settle 2 min)
#   §5  install the platform, reboot, settle 5 min, measure the idle control plane
#   §6  sample every minute for 30 minutes without touching the dashboard
#
# The dashboard is deliberately never opened: §6 wants an idle control plane, and
# leaving the admin account uncreated keeps both platforms in the same state.
source "$(dirname "$(dirname "$(readlink -f "$0")")")/lib.sh"

name="${1:?usage: run-idle-phase.sh <vm-name> [platform] [idle-minutes]}"
platform="${2:-$(vm_platform "$name")}"
minutes="${3:-30}"
log="$(result_dir "$name")/run-idle-phase.log"

exec > >(tee -a "$log") 2>&1
info "$name: starting idle phase for '$platform' at $(date -Is)"

step() { echo; info "[$name] --- $* ---"; }

step "fresh VM"
"$ROOT/vm/create-vm.sh" "$name"
"$ROOT/vm/start-vm.sh" "$name" --wait

step "provisioning"
"$ROOT/host/provision.sh" "$name" "$platform"

step "reboot before the §4 baseline"
vm_ssh "$name" "sudo systemctl reboot" >/dev/null 2>&1 || true
sleep 15; vm_wait_ssh "$name" 600

step "§4 baseline"
vm_ssh "$name" "/opt/bench/01-baseline.sh" >/dev/null

step "§5 installing $platform"
vm_ssh "$name" "/opt/bench/02-install.sh $platform"

step "reboot after install"
vm_ssh "$name" "sudo systemctl reboot" >/dev/null 2>&1 || true
sleep 15; vm_wait_ssh "$name" 600

step "§5 platform idle, after a 5 minute settle"
vm_ssh "$name" "/opt/bench/03-post-install.sh" >/dev/null

step "§6 idle for ${minutes} minutes"
vm_ssh "$name" "/opt/bench/04-idle.sh $minutes"

step "collecting results"
"$ROOT/host/pull-results.sh" "$name"

info "$name: idle phase complete at $(date -Is)"
