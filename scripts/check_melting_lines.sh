#!/usr/bin/env bash
# Every melting line against a point its source publishes, and every Clapeyron line against T dv / L_fus
# off the table's own phases. The kernel's twin is held to the same header by check_kernel_properties.sh
# (derive_melts_on_its_line).
# EXIT 0 every line holds * 1 one does not * 2 could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_godot.sh"
PROBE_REL="addons/local_agents/tests/gate_melting_lines.gd"
[ -f "$ROOT/$PROBE_REL" ] || { echo "check_melting_lines: MISSING $PROBE_REL." >&2; exit 2; }
OUT="$(LA_CPU_VALIDATION=1 la_godot --headless --path "$ROOT" -s "res://$PROBE_REL" 2>&1)"
LINE="$(printf '%s\n' "$OUT" | grep -m1 '^MELTING_LINES=')"
[ -n "$LINE" ] || { echo "check_melting_lines: the probe published no reading." >&2; printf '%s\n' "$OUT" | tail -10 >&2; exit 2; }
printf '%s\n' "$OUT" | grep -E ' melts at | melting slope ' || true
echo "$LINE"
ASKED="$(printf '%s' "$LINE" | grep -oE '"asked":[0-9]+' | grep -oE '[0-9]+$')"
FAILS="$(printf '%s' "$LINE" | grep -oE '"failures":[0-9]+' | grep -oE '[0-9]+$')"
[ "${ASKED:-0}" -gt 0 ] || { echo "check_melting_lines: nothing was examined." >&2; exit 2; }
[ "$FAILS" -eq 0 ] || exit 1
echo "check_melting_lines: OK"
