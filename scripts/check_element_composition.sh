#!/usr/bin/env bash
# ELEMENT COMPOSITION GATE — the planet's seeded elemental mass fractions, summed from its substances
# through their formulas and trace maps, must match the cited registry (LAElementAbundances): core vs
# the core model, shell vs the silicate Earth, their mass-weighted sum vs bulk Earth.
# EXIT 0 clean · 1 a violation · 2 could not run. A gate that cannot run must fail, never pass.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_godot.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_capture.sh"

SCRIPT_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
# shellcheck source=lib_require.sh
source "$SCRIPT_DIR/lib_require.sh"
require_tool godot
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

RUNNER="$SCRIPT_DIR/check_element_composition.gd"
if [[ ! -f "$RUNNER" ]]; then
  echo "ERROR: check_element_composition.sh cannot find its runner at $RUNNER." >&2
  exit 2
fi

if la_cap_dir >/dev/null; then
  OUT="$(la_headless element_composition)" || exit 2
else
  OUT="$(la_godot --headless --path "$REPO_ROOT" -s "$RUNNER" 2>&1)"
fi
SUMMARY="$(printf '%s\n' "$OUT" | grep -o 'ELEMENT_COMPOSITION=.*' | tail -n 1)"
if [[ -z "$SUMMARY" ]]; then
  echo "$OUT"
  echo "ERROR: the composition runner produced no ELEMENT_COMPOSITION= marker; nothing was checked." >&2
  exit 2
fi

ELEMENTS="$(printf '%s' "$SUMMARY" | grep -oE '"elements":[-0-9]+' | grep -oE '[-0-9]+$')"
VIOLATIONS="$(printf '%s' "$SUMMARY" | grep -oE '"violations":[-0-9]+' | grep -oE '[-0-9]+$')"

if [[ -z "${ELEMENTS:-}" || -z "${VIOLATIONS:-}" || "$VIOLATIONS" -lt 0 || "$ELEMENTS" -le 0 ]]; then
  printf '%s\n' "$OUT" | grep -E 'ELEMENT_COMPOSITION' || true
  echo "ERROR: the composition check examined $ELEMENTS element(s); the gate examined nothing." >&2
  exit 2
fi

if [[ "$VIOLATIONS" -gt 0 ]]; then
  printf '%s\n' "$OUT" | grep -E 'ELEMENT_COMPOSITION_VIOLATION' || true
  echo "element-composition check FAILED: $VIOLATIONS element(s) off the cited registry." >&2
  echo "The planet must add up to the Earth it models. Fix the formula, trace map or solve — never the" >&2
  echo "registry, whose every value is cited." >&2
  exit 1
fi

echo "element-composition check passed: $ELEMENTS element comparisons, 0 violations."
exit 0
