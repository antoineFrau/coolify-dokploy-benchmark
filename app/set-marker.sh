#!/usr/bin/env bash
# set-marker.sh <marker> -- stamp the build marker into the app source.
# Use it before every redeploy: the §10 warm build needs a real source change, and
# the deploy scripts wait for this exact value to appear at /api/items.
set -euo pipefail
marker="${1:?usage: set-marker.sh <marker>}"
f="$(dirname "$(readlink -f "$0")")/src/lib/build-marker.ts"
sed -i "s/^export const BUILD_MARKER = .*/export const BUILD_MARKER = \"$marker\";/" "$f"
grep BUILD_MARKER "$f"
