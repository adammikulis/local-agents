#!/usr/bin/env bash
# EVERY SEALED CELL IS A STATE, read against its own column: both its temperatures finite and above
# absolute zero, and its fluid between vacuum and the load its own rock carries. Read at the hydrostatic
# rung on the whole planet, where cut cells hold rock, sea and pore water in one coarse cell (under a lint
# capture, that arm), and on the slice, where the column over a fine cell is the sharp test.
# EXIT 0 every cell is a state · 1 one is not · 2 the gate could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_rung.sh"
. "$ROOT/scripts/lib_capture.sh"

FRAMES="${LA_SEALED_FRAMES:-2}"
KEYS="nonfinite_cells,solid_cells,pressure_fluid_over_col,pressure_fluid_over_col_pa,pressure_fluid_under_vacuum"

# $1 the arm's name, $2 its report block, $3 the run's exit. Exits 2 on a reading never taken.
judge() {
	la_rung_require "$2" nonfinite_cells solid_cells pressure_fluid_over_col pressure_fluid_over_col_pa \
		pressure_fluid_under_vacuum || {
		echo "check_sealed_state_range: the $1 run published no sealed state to read (exit $3)." >&2
		exit 2
	}
	local nf sealed over worst under
	nf="$(la_rung_max "$2" nonfinite_cells)"
	sealed="$(la_rung_value "$2" solid_cells)"
	over="$(la_rung_max "$2" pressure_fluid_over_col)"
	worst="$(la_rung_max "$2" pressure_fluid_over_col_pa)"
	under="$(la_rung_max "$2" pressure_fluid_under_vacuum)"
	printf 'SEALED_STATE={"arm":"%s","nonfinite_cells":%s,"sealed_cells":%s,"over_column":%s,"worst_over_pa":%s,"under_vacuum":%s}\n' \
		"$1" "$nf" "$sealed" "$over" "$worst" "$under"
	if ! awk -v s="$sealed" 'BEGIN{exit !(s > 0)}'; then
		echo "check_sealed_state_range: the $1 run read no locked cell, so no cell was held to" >&2
		echo "                          its column." >&2
		exit 2
	fi
	awk -v n="$nf" 'BEGIN{exit !(n == 0)}' || {
		echo "check_sealed_state_range: $1: $nf cell(s) hold a temperature at or below absolute zero, or a" >&2
		echo "                          non-finite state." >&2
		bad=1
	}
	awk -v n="$over" 'BEGIN{exit !(n == 0)}' || {
		echo "check_sealed_state_range: $1: $over locked cell(s) hold fluid above the load their own rock" >&2
		echo "                          carries, the worst by $worst Pa." >&2
		bad=1
	}
	awk -v n="$under" 'BEGIN{exit !(n == 0)}' || {
		echo "check_sealed_state_range: $1: $under locked cell(s) hold fluid below vacuum." >&2
		bad=1
	}
}

bad=0
body="$(la_report "$KEYS" --path "$ROOT" --body --rung 2 --frames "$FRAMES")"
judge body "$body" $?
slice="$("$ROOT/scripts/sim_run.sh" --report "$KEYS" --path "$ROOT" --slice --rung 2 --frames "$FRAMES" 2>&1)"
judge slice "$slice" $?
if [ "$bad" -ne 0 ]; then
	echo "Reproduce with: scripts/sim_run.sh --body|--slice --rung 2 --frames $FRAMES --report $KEYS" >&2
	exit 1
fi
echo "check_sealed_state_range: OK"
