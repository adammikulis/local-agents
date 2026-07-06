#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Two thresholds: a SOFT smell limit that warns (split before you cross it) and a HARD limit that FAILS
# the build. A first-party source/config file over the hard limit must be split into focused modules.
SOFT_FILE_LINES="${SOFT_FILE_LINES:-800}"
MAX_FILE_LINES="${MAX_FILE_LINES:-1000}"

for v in "$SOFT_FILE_LINES" "$MAX_FILE_LINES"; do
  if ! [[ "$v" =~ ^[0-9]+$ ]] || [[ "$v" -le 0 ]]; then
    echo "SOFT_FILE_LINES / MAX_FILE_LINES must be positive integers (got soft=$SOFT_FILE_LINES hard=$MAX_FILE_LINES)"
    exit 2
  fi
done

# Test-invocation safety gate (genuine correctness check, kept as a hard gate).
"$SCRIPT_DIR/check_no_direct_refcounted_invocation.sh"
# NOTE: the policy/plan marker check is intentionally NOT invoked here. It used to
# be bundled in, which secretly turned this "advisory" file-length check into a
# hard marker gate under `set -euo pipefail`. Marker checks are now advisory and
# run separately (see scripts/check_policy_plan_markers.sh, invoked by the lint
# harness as advisory-only).

FILES=()
while IFS= read -r file; do
  FILES+=("$file")
done < <(
  rg --files addons/local_agents scripts .github/workflows \
    -g '*.gd' -g '*.gdshader' -g '*.tscn' -g '*.tres' -g '*.yml' -g '*.yaml' \
  | rg -v '/gdextensions/localagents/(thirdparty|build|build_native)/' \
  | rg -v '/build_native/'
)

if [[ ${#FILES[@]} -eq 0 ]]; then
  echo "No matching files found for max-file-length check."
  exit 0
fi

warnings=0
violations=0
for file in "${FILES[@]}"; do
  if [[ ! -f "$file" ]]; then
    continue
  fi
  lines=$(wc -l < "$file" | tr -d '[:space:]')
  if [[ "$lines" -gt "$MAX_FILE_LINES" ]]; then
    echo "ERROR: FILE OVER HARD LIMIT: $file ($lines lines > $MAX_FILE_LINES hard limit) — split it into focused modules."
    violations=$((violations + 1))
  elif [[ "$lines" -gt "$SOFT_FILE_LINES" ]]; then
    echo "WARNING: FILE OVER SOFT LIMIT: $file ($lines lines > $SOFT_FILE_LINES soft limit) — split before it crosses $MAX_FILE_LINES."
    warnings=$((warnings + 1))
  fi
done

echo
if [[ "$violations" -gt 0 ]]; then
  echo "Max file length check FAILED: $violations file(s) over the ${MAX_FILE_LINES}-line HARD limit ($warnings over the ${SOFT_FILE_LINES}-line soft limit)."
  echo "Do NOT add to a file over the hard limit — refactor it into new focused modules first."
  exit 1
fi
if [[ "$warnings" -gt 0 ]]; then
  echo "Max file length check passed (hard limit ${MAX_FILE_LINES}); $warnings file(s) over the ${SOFT_FILE_LINES}-line soft limit — split them soon (advisory)."
else
  echo "Max file length check passed (soft ${SOFT_FILE_LINES}, hard ${MAX_FILE_LINES} lines)."
fi
exit 0
