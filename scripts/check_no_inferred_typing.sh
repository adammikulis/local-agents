#!/usr/bin/env bash
# Project rule: no GDScript inferred typing (:=). Declare explicit types instead.
# Scans GDScript for the ':=' operator. Enforced (exit 1) for the new voxel scene;
# repo-wide hits are reported as advisory.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Directories where ':=' is a hard failure. Add a directory here once its ':=' sweep is done —
# an array (not a single dir) so widening coverage is a one-line append, not a rewrite.
ENFORCED_DIRS=(
  "addons/local_agents/sim"
  "addons/local_agents/game"
  "addons/local_agents/controllers"
  "addons/local_agents/graph"
)

# A directory that has been renamed or split away silently removes itself from enforcement: the grep
# below sends its "No such file or directory" to /dev/null and ends in `|| true`, so the hit list comes
# back empty and the gate prints OK. The pass condition is the ABSENCE of ':=' — absence from a directory
# that was not read is not evidence. Prove each root exists and holds GDScript before trusting that.
scanned=0
for d in "${ENFORCED_DIRS[@]}"; do
  if [[ ! -d "$d" ]]; then
    echo "ERROR: check_no_inferred_typing.sh enforced directory '$d' does not exist." >&2
    echo "       It was renamed or removed and this gate stopped covering it silently. Update" >&2
    echo "       ENFORCED_DIRS, do not leave a stale entry that enforces nothing." >&2
    exit 2
  fi
  n=$(find "$d" -name '*.gd' -type f | grep -c . || true)
  scanned=$((scanned + n))
done
if [[ "$scanned" -eq 0 ]]; then
  echo "ERROR: check_no_inferred_typing.sh found zero .gd files across ${ENFORCED_DIRS[*]}." >&2
  echo "       Refusing to report a pass on zero files." >&2
  exit 2
fi

# Match ' := ' assignments (avoids matching '==', '<=', '>=', ':=' only as the walrus infer op).
PATTERN=':='

# Strip trailing comments before matching so ':=' in doc-comments (e.g. the "no ':='" rule note itself)
# doesn't trip the gate. Both the enforced check AND the advisory repo count strip comments the same way,
# so a file whose ONLY ':=' is inside a comment is treated as clean, not a false-positive "legacy" hit.
enforced_hits=$(grep -rnE "[^:]${PATTERN}[^=]" "${ENFORCED_DIRS[@]}" --include='*.gd' 2>/dev/null \
  | awk -F: '{ code=$0; sub(/^[^:]*:[0-9]+:/,"",code); sub(/#.*/,"",code); if (code ~ /[^:]:=[^=]/) print }' || true)
repo_hits=$(grep -rnE "[^:]${PATTERN}[^=]" addons --include='*.gd' 2>/dev/null \
  | awk -F: '{ file=$1; code=$0; sub(/^[^:]*:[0-9]+:/,"",code); sub(/#.*/,"",code); if (code ~ /[^:]:=[^=]/) print file }' \
  | sort -u | wc -l | tr -d ' ')

if [ -n "$enforced_hits" ]; then
  # NOTE: this used to interpolate $ENFORCED_DIR, which no longer exists — under `set -u` that
  # aborted the script with "unbound variable" instead of printing the offending lines.
  echo "FAIL: inferred typing ':=' found in an enforced directory (use explicit types):"
  printf '  enforced: %s\n' "${ENFORCED_DIRS[@]}"
  echo "$enforced_hits"
  echo "check_no_inferred_typing: FAIL"
  exit 1
fi
echo "check_no_inferred_typing: OK (${#ENFORCED_DIRS[@]} enforced dirs, $scanned .gd files clean; $repo_hits legacy files repo-wide still use ':=')"
