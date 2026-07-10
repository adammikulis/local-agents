#!/usr/bin/env bash
# Project rule: no GDScript inferred typing (:=). Declare explicit types instead.
# Scans GDScript for the ':=' operator. Enforced (exit 1) for the new voxel scene;
# repo-wide hits are reported as advisory.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

ENFORCED_DIR="addons/local_agents/scenes/simulation/voxel"

# Match ' := ' assignments (avoids matching '==', '<=', '>=', ':=' only as the walrus infer op).
PATTERN=':='

# Strip trailing comments before matching so ':=' in doc-comments (e.g. the "no ':='" rule note itself)
# doesn't trip the gate. Both the enforced check AND the advisory repo count strip comments the same way,
# so a file whose ONLY ':=' is inside a comment is treated as clean, not a false-positive "legacy" hit.
enforced_hits=$(grep -rnE "[^:]${PATTERN}[^=]" "$ENFORCED_DIR" --include='*.gd' 2>/dev/null \
  | awk -F: '{ code=$0; sub(/^[^:]*:[0-9]+:/,"",code); sub(/#.*/,"",code); if (code ~ /[^:]:=[^=]/) print }' || true)
repo_hits=$(grep -rnE "[^:]${PATTERN}[^=]" addons --include='*.gd' 2>/dev/null \
  | awk -F: '{ file=$1; code=$0; sub(/^[^:]*:[0-9]+:/,"",code); sub(/#.*/,"",code); if (code ~ /[^:]:=[^=]/) print file }' \
  | sort -u | wc -l | tr -d ' ')

if [ -n "$enforced_hits" ]; then
  echo "FAIL: inferred typing ':=' found in $ENFORCED_DIR (use explicit types):"
  echo "$enforced_hits"
  echo "check_no_inferred_typing: FAIL"
  exit 1
fi
echo "check_no_inferred_typing: OK (enforced dir clean; $repo_hits legacy files repo-wide still use ':=')"
