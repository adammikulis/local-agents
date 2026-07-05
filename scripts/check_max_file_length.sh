#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAX_FILE_LINES="${MAX_FILE_LINES:-1000}"

if ! [[ "$MAX_FILE_LINES" =~ ^[0-9]+$ ]] || [[ "$MAX_FILE_LINES" -le 0 ]]; then
  echo "MAX_FILE_LINES must be a positive integer (got: $MAX_FILE_LINES)"
  exit 2
fi

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

violations=0
for file in "${FILES[@]}"; do
  if [[ ! -f "$file" ]]; then
    continue
  fi
  lines=$(wc -l < "$file" | tr -d '[:space:]')
  if [[ "$lines" -gt "$MAX_FILE_LINES" ]]; then
    echo "WARNING: FILE OVER SOFT LIMIT: $file ($lines lines > $MAX_FILE_LINES soft limit)"
    violations=$((violations + 1))
  fi
done

# Soft limit only: report oversize files as advisory warnings, but never fail CI.
if [[ "$violations" -gt 0 ]]; then
  echo
  echo "Max file length check found $violations file(s) over the ${MAX_FILE_LINES}-line soft limit (warning only)."
  echo "Consider splitting large files into focused modules; this is advisory and does not fail the build."
else
  echo "Max file length check passed (soft limit: $MAX_FILE_LINES lines)."
fi
exit 0
