#!/usr/bin/env bash
# THE FAINT-YOUNG-SUN GATE — under the epoch's dimmed sun the seeded greenhouse must hold a
# band-resolved radiative-equilibrium surface above 273.15 K, and the built-in no-greenhouse arm
# must freeze, through the same table and composition the sim runs.
# EXIT 0 liquid water persists · 1 frozen, or the bare arm fails to freeze · 2 could not run.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_godot.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_capture.sh"
la_examined "$(basename "$0")" || exit $?

SCRIPT_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
# shellcheck source=lib_require.sh
source "$SCRIPT_DIR/lib_require.sh"
require_tool godot
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

RUNNER="$SCRIPT_DIR/check_faint_young_sun.gd"
[[ -f "$RUNNER" ]] || { echo "ERROR: no runner at $RUNNER." >&2; exit 2; }

if la_cap_dir >/dev/null; then
  OUT="$(la_headless faint_young_sun)" || exit 2
else
  OUT="$(la_godot --headless --path "$REPO_ROOT" -s "$RUNNER" 2>&1)"
fi
SUMMARY="$(printf '%s\n' "$OUT" | grep -o 'FAINT_YOUNG_SUN=.*' | tail -n 1)"
if [[ -z "$SUMMARY" ]]; then
  printf '%s\n' "$OUT" | tail -20 >&2
  echo "ERROR: the runner produced no FAINT_YOUNG_SUN= marker; nothing was checked." >&2
  exit 2
fi
echo "$SUMMARY"
# THE VERDICT IS THE MARKER'S, not the process exit code: under the batched capture every runner shares
# one launch, so an exit code would report the batch and a frozen planet would read as a pass.
FAILURES="$(printf '%s\n' "$SUMMARY" | sed -n 's/.*"failures":\([0-9][0-9]*\).*/\1/p')"
case "$FAILURES" in "" | *[!0-9]*) echo "ERROR: the marker carries no failure count." >&2; exit 2 ;; esac
if [[ "$FAILURES" -gt 0 ]]; then
  echo
  echo "Either the honest greenhouse freezes the planet under the faint young sun — a physics finding"
  echo "to report, never a constant to tune — or the no-greenhouse arm failed to freeze, which means"
  echo "this gate is no longer measuring the greenhouse at all."
  exit 1
fi
echo "check_faint_young_sun: OK"
