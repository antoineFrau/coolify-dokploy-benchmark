#!/usr/bin/env bash
# Generate package-lock.json for the app and the worker using the same node image
# the Dockerfiles use. Run once and commit the lockfiles: identical dependency
# resolution on both platforms is a §2 fairness requirement.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"

run() { docker run --rm -v "$PWD:/w" -w "$1" -u "$(id -u):$(id -g)" \
        -e npm_config_cache=/tmp/npm node:22-slim npm install --package-lock-only --no-audit --no-fund; }

echo "==> app lockfile";    run /w
echo "==> worker lockfile"; run /w/worker
echo "==> done"
