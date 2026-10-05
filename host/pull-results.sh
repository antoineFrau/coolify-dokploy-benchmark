#!/usr/bin/env bash
# pull-results.sh <vm-name> -- copy everything the VM recorded into results/<vm>/.
source "$(dirname "$(dirname "$(readlink -f "$0")")")/lib.sh"

name="${1:?usage: pull-results.sh <vm-name>}"
dest="$(result_dir "$name")"
vm_ssh "$name" "tar -C /opt/bench -cz results" | tar -C "$dest" -xz --strip-components=1
info "$name: results in $dest"
ls -la "$dest" | sed 's/^/    /'
