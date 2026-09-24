#!/usr/bin/env bash
# EVERY SEALED CELL IS A STATE: both its temperatures finite and above absolute zero, and its fluid's
# pressure between vacuum and the greatest pressure the rock column states.
# By hand it takes the whole planet at the hydrostatic rung, where cut cells hold rock, sea and pore water
# in one cell; under a lint capture it reads that arm.
# EXIT 0 every cell is a state · 1 one is not · 2 the gate could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_rung.sh"
. "$ROOT/scripts/lib_capture.sh"

FRAMES="${LA_SEALED_FRAMES:-2}"
KEYS="nonfinite_cells,pressure_col_max,pressure_fluid_max,pressure_fluid_min"
out="$(la_report "$KEYS" --path "$ROOT" --body --rung 2 --frames "$FRAMES")"
rc=$?
la_rung_require "$out" nonfinite_cells pressure_col_max pressure_fluid_max pressure_fluid_min || {
	echo "check_sealed_state_range: the run published no sealed state to read (exit $rc)." >&2
	exit 2
}
nf="$(la_rung_max "$out" nonfinite_cells)"
col="$(la_rung_min "$out" pressure_col_max)"
f_hi="$(la_rung_max "$out" pressure_fluid_max)"
f_lo="$(la_rung_min "$out" pressure_fluid_min)"
printf 'SEALED_STATE={"nonfinite_cells":%s,"column_max_pa":%s,"fluid_pa":[%s,%s]}\n' "$nf" "$col" "$f_lo" "$f_hi"
if ! awk -v c="$col" 'BEGIN{exit !(c > 0)}'; then
	echo "check_sealed_state_range: no locked cell states a column, so there is no range to hold a cell to." >&2
	exit 2
fi
bad=0
awk -v n="$nf" 'BEGIN{exit !(n == 0)}' || {
	echo "check_sealed_state_range: $nf cell(s) hold a temperature at or below absolute zero, or a" >&2
	echo "                          non-finite state." >&2
	bad=1
}
awk -v f="$f_lo" 'BEGIN{exit !(f >= 0)}' || {
	echo "check_sealed_state_range: a cell's fluid stands below vacuum ($f_lo Pa)." >&2
	bad=1
}
awk -v f="$f_hi" -v c="$col" 'BEGIN{exit !(f <= c)}' || {
	echo "check_sealed_state_range: a cell's fluid stands above the deepest rock's column ($f_hi Pa" >&2
	echo "                          against $col Pa)." >&2
	bad=1
}
if [ "$bad" -ne 0 ]; then
	echo "Reproduce with: scripts/sim_run.sh --body --rung 2 --frames $FRAMES --report $KEYS" >&2
	exit 1
fi
echo "check_sealed_state_range: OK"
