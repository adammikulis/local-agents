#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib_require.sh
source "$SCRIPT_DIR/lib_require.sh"
require_tool rg   # without this the file list comes back empty and the gate passes on zero files
# The scan roots below are RELATIVE. Without this cd they resolve against the caller's directory, rg
# prints "No such file or directory" four times, the list comes back empty and the gate exits 0 having
# examined nothing — the same vacuous pass require_tool was added to stop, reached by a different road.
# Measured 2026-08-09: run from a scratch directory this printed "No matching files found" and exit 0.
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"
# Two thresholds: a SOFT smell limit that warns (split before you cross it) and a HARD limit that FAILS
# the build. A first-party source/config file over the hard limit must be split into focused modules.
SOFT_FILE_LINES="${SOFT_FILE_LINES:-1300}"
MAX_FILE_LINES="${MAX_FILE_LINES:-1500}"

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

# MARKDOWN IS CHECKED TOO (added 2026-07-29). Docs rot the same way source does: API.md reached 1480 lines
# and nothing warned, because this list globbed source extensions only. Prose over the soft limit is the same
# problem as code over it — nobody reads to the bottom, and claims at the bottom go stale unnoticed.
# `docs/` and the repo-root .md files (HANDOFF.md, CLAUDE.md, GODOT_BEST_PRACTICES.md,
# README.md) were never scanned by any root in this list, so they are added here explicitly. Third-party
# markdown under gdextensions/ stays excluded by the filters below.
FILES=()
while IFS= read -r file; do
  FILES+=("$file")
done < <(
  {
    rg --files addons/local_agents scripts .github/workflows docs \
      -g '*.gd' -g '*.gdshader' -g '*.tscn' -g '*.tres' -g '*.yml' -g '*.yaml' -g '*.md'
    rg --files --max-depth 1 . -g '*.md'
  } \
  | rg -v '/gdextensions/localagents/(thirdparty|build|build_native)/' \
  | rg -v '/build_native/'
)

# An empty list is never a pass. This tree has hundreds of matching files, so zero means the roots moved,
# a glob broke, or rg failed — every one of which leaves the gate measuring nothing. Exit 2 (could not
# run), never 0. This branch used to `exit 0` with the message below, which is verbatim what CI printed on
# every push for months while ripgrep was missing from the runner.
if [[ ${#FILES[@]} -eq 0 ]]; then
  echo "ERROR: no matching files found for max-file-length check under $REPO_ROOT." >&2
  echo "       Refusing to report a pass on zero files — the scan roots or globs are wrong." >&2
  exit 2
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
