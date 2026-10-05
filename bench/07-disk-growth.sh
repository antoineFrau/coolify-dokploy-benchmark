#!/usr/bin/env bash
# §13 -- disk growth across repeated builds. Call after 0, 1, 5, 10 and 20 builds:
#   07-disk-growth.sh record <build-count>
# Captures docker system df -v in full as well, so images / build cache / volumes /
# logs can be attributed individually rather than guessed at.
source "$(dirname "$(readlink -f "$0")")/lib.sh"

cmd="${1:?usage: 07-disk-growth.sh record <build-count>}"
[ "$cmd" = record ] || die "unknown command '$cmd'"
n="${2:?build count}"

snap disk-growth "builds-$n" --du >/dev/null
docker system df -v > "$RES/disk-growth.builds-$n.txt" 2>&1 || true
sudo du -sh /var/lib/docker/* /var/lib/containerd/* 2>/dev/null | sort -rh \
    >> "$RES/disk-growth.builds-$n.txt" || true
# Container logs are a classic slow leak on a 50 GB box; measure them explicitly.
sudo du -sb /var/lib/docker/containers 2>/dev/null | awk '{print "containers_dir_bytes="$1}' \
    >> "$RES/disk-growth.builds-$n.txt" || true

python3 - "$RES/disk-growth.jsonl" "$n" <<'PY'
import json, sys
row = json.loads(open(sys.argv[1]).read().strip().splitlines()[-1])
df = row["docker_df"]
print(json.dumps({
    "builds": int(sys.argv[2]),
    "root_used_gb": round(row["disk_root"]["used_bytes"] / 1e9, 2),
    "root_used_pct": row["disk_root"]["used_pct"],
    "docker_storage_gb": round((row.get("docker_dir_bytes") or 0) / 1e9, 2),
    "var_lib_docker_gb": round(row.get("docker_storage", {}).get("docker", 0) / 1e9, 2),
    "var_lib_containerd_gb": round(row.get("docker_storage", {}).get("containerd", 0) / 1e9, 2),
    "images_gb": round(df.get("images", {}).get("size_bytes", 0) / 1e9, 2),
    "build_cache_gb": round(df.get("build_cache", {}).get("size_bytes", 0) / 1e9, 2),
    "volumes_gb": round(df.get("local_volumes", {}).get("size_bytes", 0) / 1e9, 2),
}, indent=2))
PY
