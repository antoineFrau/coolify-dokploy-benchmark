#!/usr/bin/env bash
# Shared helpers for the Coolify vs Dokploy benchmark harness (host side).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_DIR="$ROOT/vm/run"
IMG_DIR="$RUN_DIR/images"
KEY="$RUN_DIR/id_ed25519"
RESULTS="$ROOT/results"

UBUNTU_RELEASE="noble"
UBUNTU_IMG="${UBUNTU_RELEASE}-server-cloudimg-amd64.img"
UBUNTU_URL="https://cloud-images.ubuntu.com/${UBUNTU_RELEASE}/current/${UBUNTU_IMG}"

VM_CPUS=4
VM_MEM=8192        # MiB
VM_DISK=50G

die()  { echo "error: $*" >&2; exit 1; }
info() { echo "==> $*"; }

# vm_field <name> <column-index>
# columns: 1 name 2 ssh 3 http 4 https 5 ui_host 6 ui_guest 7 platform 8 extra_fwd
vm_field() {
    local name="$1" idx="$2"
    awk -v n="$name" -v i="$idx" '!/^#/ && NF && $1==n {print $i; found=1} END{exit !found}' \
        "$ROOT/vms.conf" || die "unknown VM '$name' (see vms.conf)"
}

vm_names()    { awk '!/^#/ && NF {print $1}' "$ROOT/vms.conf"; }
vm_ssh_port() { vm_field "$1" 2; }
vm_http()     { vm_field "$1" 3; }
vm_https()    { vm_field "$1" 4; }
vm_ui_host()  { vm_field "$1" 5; }
vm_ui_guest() { vm_field "$1" 6; }
vm_platform() { vm_field "$1" 7; }
vm_extra_fwd() { vm_field "$1" 8; }

vm_dir() { echo "$RUN_DIR/$1"; }

vm_pid() {
    local p="$(vm_dir "$1")/qemu.pid"
    [ -f "$p" ] || return 1
    local pid; pid="$(cat "$p")"
    kill -0 "$pid" 2>/dev/null || return 1
    echo "$pid"
}

vm_running() { vm_pid "$1" >/dev/null 2>&1; }

SSH_OPTS=(-i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o LogLevel=ERROR -o ConnectTimeout=5 -o ServerAliveInterval=15)

vm_ssh()  { local n="$1"; shift; ssh "${SSH_OPTS[@]}" -p "$(vm_ssh_port "$n")" ubuntu@127.0.0.1 "$@"; }
vm_scp()  { local n="$1"; shift; scp "${SSH_OPTS[@]}" -P "$(vm_ssh_port "$n")" "$@"; }
vm_rsync_dir() {  # vm_rsync_dir <vm> <local-dir> <remote-parent>
    local n="$1" src="$2" dst="$3"
    vm_ssh "$n" "mkdir -p '$dst'"
    tar -C "$(dirname "$src")" -cz "$(basename "$src")" | vm_ssh "$n" "tar -C '$dst' -xz"
}

vm_wait_ssh() {
    local n="$1" timeout="${2:-300}" start; start=$(date +%s)
    while ! vm_ssh "$n" true 2>/dev/null; do
        vm_running "$n" || die "$n: qemu died (see $(vm_dir "$n")/console.log)"
        [ $(( $(date +%s) - start )) -lt "$timeout" ] || die "$n: ssh not ready after ${timeout}s"
        sleep 3
    done
}

# Elapsed seconds since an epoch stamp, as a float.
elapsed_since() { python3 -c "import sys;print(f'{__import__(\"time\").time()-float(sys.argv[1]):.1f}')" "$1"; }

# Send a command to a VM's QEMU monitor (socat is not assumed to be installed).
monitor_cmd() {
    local sock="$(vm_dir "$1")/monitor.sock" cmd="$2"
    [ -S "$sock" ] || return 1
    python3 -c 'import socket,sys,time; s=socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); s.sendall((sys.argv[2]+"\n").encode()); time.sleep(0.5); s.close()' "$sock" "$cmd"
}

result_dir() { local d="$RESULTS/$1"; mkdir -p "$d"; echo "$d"; }
