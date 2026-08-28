#!/usr/bin/env bash
# EVERY CONDENSED PHASE HAS A BULK MODULUS, because every real solid and liquid does. A channel whose
# substance declares none is read as incompressible, which makes its cell's mixture infinitely stiff and
# lets a signal cross it at any speed at all. Gases have no such modulus and a dissolved solute rides in
# its solvent, so neither is asked for one.
# EXIT 0 every condensed channel is measured * 1 one is not * 2 could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_godot.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_capture.sh"

PROBE_REL="addons/local_agents/tests/gate_condensed_moduli.gd"
[ -f "$ROOT/$PROBE_REL" ] || { echo "check_condensed_moduli: MISSING $PROBE_REL." >&2; exit 2; }

if la_cap_dir >/dev/null; then
	OUT="$(la_headless condensed_moduli)" || exit 2
else
	OUT="$(la_godot --headless --path "$ROOT" -s "res://$PROBE_REL" 2>&1)"
fi

LINE="$(printf '%s\n' "$OUT" | grep -m1 '^CONDENSED_MODULI=')"
[ -n "$LINE" ] || {
	echo "check_condensed_moduli: the probe published no reading, so the table was never read." >&2
	printf '%s\n' "$OUT" | tail -15 >&2
	exit 2
}
printf '%s\n' "$OUT" | grep -E '^condensed with no bulk modulus' || true
echo "$LINE"
# A channel table nobody read asserts nothing; the marker carries the verdict.
ASKED="$(printf '%s' "$LINE" | grep -oE '"asked":[0-9]+' | grep -oE '[0-9]+$')"
FAILS="$(printf '%s' "$LINE" | grep -oE '"failures":[0-9]+' | grep -oE '[0-9]+$')"
{ [ -n "$ASKED" ] && [ -n "$FAILS" ]; } || {
	echo "check_condensed_moduli: the probe published no counts." >&2; exit 2; }
[ "$ASKED" -gt 0 ] || {
	echo "check_condensed_moduli: no condensed channel was examined, so this gate asserts nothing." >&2
	exit 2
}
[ "$FAILS" -eq 0 ] || exit 1
echo "check_condensed_moduli: OK"
