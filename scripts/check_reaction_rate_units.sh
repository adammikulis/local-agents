#!/usr/bin/env bash
# RATE-UNITS GATE — rate_k had a different dimension in every record and nothing checked it.

# WHAT IT CHECKS:
#   1. every record declares k_timebase (per_real_second / per_step) and k_units, and the declaration
#      matches its rate model (LAReactionDefs.check_rate_units, the same check the runtime refusal calls);
#   2. no record module folds real_seconds_per_step into its own k — LAReactionDefs.serialize() is the ONE
#      place the step quantum enters a rate, so it cannot be counted twice;
#   3. reactions_sphere3d.glsl declares no dt push-constant member — a kernel-side dt would double-count
#      every per-second record.

# EXIT 0 clean · 1 a violation · 2 could not run. A gate that cannot run must fail, never pass.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_godot.sh"

SCRIPT_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
# shellcheck source=lib_require.sh
source "$SCRIPT_DIR/lib_require.sh"
require_tool godot
require_tool rg
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

REACTIONS_DIR="$REPO_ROOT/addons/local_agents/sim/material/reactions"
KERNEL="$REPO_ROOT/addons/local_agents/sim/material/kernels3d/reactions_sphere3d.glsl"
[ -d "$REACTIONS_DIR" ] || { echo "ERROR: $REACTIONS_DIR is gone; nothing was checked." >&2; exit 2; }
[ -f "$KERNEL" ] || { echo "ERROR: $KERNEL is gone; nothing was checked." >&2; exit 2; }

FAIL=0

# --- 2. Record modules may not fold the step quantum themselves -------------------------------------------
FOLDS="$(rg -n "real_seconds_per_step" "$REACTIONS_DIR" --glob '*Records.gd' || true)"
if [ -n "$FOLDS" ]; then
  echo "rate-units check FAILED: a record module folds real_seconds_per_step into its own k. The step" >&2
  echo "quantum enters a rate exactly once, in LAReactionDefs.serialize(); declare the record" >&2
  echo "k_timebase = per_real_second instead." >&2
  printf '%s\n' "$FOLDS" >&2
  FAIL=1
fi

# --- 3. The kernel carries no dt --------------------------------------------------------------------------
if rg -qe '^[[:space:]]*(float|uint)[[:space:]]+dt\b' "$KERNEL"; then
  echo "rate-units check FAILED: reactions_sphere3d.glsl declares a dt. Every rate_k already carries its" >&2
  echo "own timebase, so a kernel-side dt double-counts every per-second record." >&2
  FAIL=1
fi

# --- 1. Every record's declaration matches its model -------------------------------------------------------
RUNNER="$SCRIPT_DIR/check_reaction_rate_units.gd"
if [[ ! -f "$RUNNER" ]]; then
  echo "ERROR: check_reaction_rate_units.sh cannot find its runner at $RUNNER." >&2
  exit 2
fi
OUT="$(la_godot --headless --path "$REPO_ROOT" -s "$RUNNER" 2>&1)"
SUMMARY="$(printf '%s\n' "$OUT" | grep -o 'RATE_UNITS=.*' | tail -n 1)"
if [[ -z "$SUMMARY" ]]; then
  echo "$OUT"
  echo "ERROR: the rate-units runner produced no RATE_UNITS= marker, so nothing was checked." >&2
  exit 2
fi
RECORDS="$(printf '%s' "$SUMMARY" | grep -oE '"records":[-0-9]+' | grep -oE '[-0-9]+$')"
VIOLATIONS="$(printf '%s' "$SUMMARY" | grep -oE '"violations":[-0-9]+' | grep -oE '[-0-9]+$')"
if [[ -z "${RECORDS:-}" || -z "${VIOLATIONS:-}" || "$VIOLATIONS" -lt 0 || "$RECORDS" -le 0 ]]; then
  printf '%s\n' "$OUT" | grep -E 'RATE_UNITS' || true
  echo "ERROR: the reaction table parsed to ${RECORDS:-0} record(s); the gate examined nothing." >&2
  exit 2
fi
if [[ "$VIOLATIONS" -gt 0 ]]; then
  printf '%s\n' "$OUT" | grep -E 'RATE_UNITS_VIOLATION' || true
  echo "rate-units check FAILED: $VIOLATIONS violation(s) across $RECORDS record(s)." >&2
  FAIL=1
fi

if [[ "$FAIL" -ne 0 ]]; then
  exit 1
fi
echo "rate-units check passed: $RECORDS records, 0 violations."
exit 0
