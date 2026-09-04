#!/usr/bin/env bash
# HYPSOMETRY GATE — the seeded body's surface-height histogram against Earth's own hypsographic curve,
# declared and cited in LAPhysical. A relief that is a typed amplitude reads its own distribution instead.
# MUTATION: scale the elevation LAPlanetShape.hypsometric_curve() lays along the cascade by 3 -> red.
# EXIT 0 the body matches the curve · 1 it does not · 2 the gate could not run.
set -uo pipefail
SCRIPT_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
# shellcheck source=lib_require.sh
source "$SCRIPT_DIR/lib_require.sh"
# shellcheck source=lib_godot.sh
source "$SCRIPT_DIR/lib_godot.sh"
# shellcheck source=lib_capture.sh
source "$SCRIPT_DIR/lib_capture.sh"
require_tool godot
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

RUNNER="$SCRIPT_DIR/check_hypsometry.gd"
[ -f "$RUNNER" ] || { echo "ERROR: check_hypsometry.sh cannot find its runner at $RUNNER." >&2; exit 2; }

if la_cap_dir >/dev/null; then
  OUT="$(la_headless hypsometry)" || exit 2
else
  OUT="$(la_godot --headless --path "$REPO_ROOT" -s "$RUNNER" 2>&1)"
fi
SUMMARY="$(printf '%s\n' "$OUT" | grep -o 'HYPSOMETRY={.*}' | tail -n 1)"
if [ -z "$SUMMARY" ]; then
  printf '%s\n' "$OUT" | tail -20
  echo "ERROR: the hypsometry runner published no HYPSOMETRY= marker; nothing was checked." >&2
  exit 2
fi

COMPARED="$(printf '%s' "$SUMMARY" | grep -oE '"compared":[-0-9]+' | grep -oE '[-0-9]+$')"
VIOLATIONS="$(printf '%s' "$SUMMARY" | grep -oE '"violations":[-0-9]+' | grep -oE '[-0-9]+$')"
if [ -z "${COMPARED:-}" ] || [ -z "${VIOLATIONS:-}" ] || [ "$COMPARED" -le 0 ] || [ "$VIOLATIONS" -lt 0 ]; then
  echo "$SUMMARY" >&2
  echo "ERROR: the hypsometry check compared nothing, so it asserts nothing about the body." >&2
  exit 2
fi

echo "$SUMMARY"
if [ "$VIOLATIONS" -gt 0 ]; then
  printf '%s\n' "$OUT" | grep 'HYPSOMETRY_VIOLATION' || true
  echo >&2
  echo "The seeded body does not stand where Earth's hypsographic curve says a planet's surface stands." >&2
  echo "Fix the shape the generator lays, never the curve: every elevation in it is a measurement." >&2
  exit 1
fi
echo "check_hypsometry: OK ($COMPARED comparisons)"
exit 0
