#!/usr/bin/env bash
# THE SEED-DECISIONS GATE — the surface temperature, the mantle potential temperature, the N2 inventory
# and the spin axis, each against what it is derived from or cited to. Every arm carries a control the
# same test must reject, so the gate cannot pass with the derivation gone.
# EXIT 0 all four hold · 1 one does not, or a control passed · 2 could not run.
set -uo pipefail
SCRIPT_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
. "$SCRIPT_DIR/lib_godot.sh"
. "$SCRIPT_DIR/lib_capture.sh"
. "$SCRIPT_DIR/lib_require.sh"
la_examined "$(basename "$0")" || exit $?
require_tool godot
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

RUNNER="$SCRIPT_DIR/check_seed_decisions.gd"
[[ -f "$RUNNER" ]] || { echo "ERROR: no runner at $RUNNER." >&2; exit 2; }

if la_cap_dir >/dev/null; then
  OUT="$(la_headless seed_decisions)" || exit 2
else
  OUT="$(la_godot --headless --path "$REPO_ROOT" -s "$RUNNER" 2>&1)"
fi
SUMMARY="$(printf '%s\n' "$OUT" | grep -o 'SEED_DECISIONS=.*' | tail -n 1)"
if [[ -z "$SUMMARY" ]]; then
  printf '%s\n' "$OUT" | tail -20 >&2
  echo "ERROR: the runner produced no SEED_DECISIONS= marker; nothing was checked." >&2
  exit 2
fi
echo "$SUMMARY"
# THE VERDICT IS THE MARKER'S, not the process exit code: under the batched capture every runner shares
# one launch, so an exit code would report the batch and a failing arm would read as a pass.
FAILURES="$(printf '%s\n' "$SUMMARY" | sed -n 's/.*"failures":\([0-9][0-9]*\).*/\1/p')"
case "$FAILURES" in "" | *[!0-9]*) echo "ERROR: the marker carries no failure count." >&2; exit 2 ;; esac
if [[ "$FAILURES" -gt 0 ]]; then
  printf '%s\n' "$OUT" | grep 'SEED_DECISIONS_VIOLATION' >&2
  echo >&2
  echo "A seed value no longer follows from what it is derived from, or a control arm passed, which" >&2
  echo "means that arm is no longer measuring the derivation." >&2
  exit 1
fi
echo "check_seed_decisions: OK"
