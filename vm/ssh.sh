#!/usr/bin/env bash
# ssh.sh <vm-name> [command...] -- shell into a benchmark VM.
source "$(dirname "$(dirname "$(readlink -f "$0")")")/lib.sh"
name="${1:?usage: ssh.sh <vm-name> [command...]}"; shift
vm_ssh "$name" "$@"
