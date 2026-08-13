#!/usr/bin/env bash
# GDSCRIPT IS THE BUDGET. The substrate runs on the GPU, and what cannot go to the GPU goes to C++; what
# is left in GDScript is bindings. Two counts over addons/local_agents/sim, each a RATCHET: it may fall,
# it may not rise, and when it falls the ceiling comes down with it in the same commit.
#
# The second count is the one that names the defect directly. A loop whose bound is a cell count is a
# reduction over data that already lives on the device, run in an interpreter after being downloaded.
#
# EXIT 0 clean · 1 a ceiling breached, or a ceiling left standing above the real count · 2 could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh" 2>/dev/null || true
require_tool rg
require_tool wc

SIM="$ROOT/addons/local_agents/sim"
[ -d "$SIM" ] || { echo "check_gdscript_budget: MISSING $SIM" >&2; exit 2; }

LINES_CEIL_FILE="$ROOT/docs/GDSCRIPT_LINES_CEILING"
LOOPS_CEIL_FILE="$ROOT/docs/CELL_LOOP_CEILING"

# A cell-bounded iteration, in either spelling GDScript offers.
LOOP_RE='for [a-zA-Z_][a-zA-Z0-9_]* in (cc|_cc|cell_count|_cell_count|_f\._cell_count|[a-zA-Z_]*grid\.cell_count)\b|while [a-zA-Z_][a-zA-Z0-9_]* < (cc|_cc|cell_count|_cell_count|_f\._cell_count|[a-zA-Z_]*grid\.cell_count)\b'

# Assigns to CEILING. NOT a command substitution: an `exit 2` inside one leaves only the subshell, and the
# gate then reports OK on a ceiling file it could not read. That is the shape this repo has shipped three
# times, and arm (d) of this gate's own mutation test is what found it here.
CEILING=""
read_ceiling() {  # read_ceiling <file>
	local f="$1"
	[ -f "$f" ] || { echo "check_gdscript_budget: no ceiling file at ${f#"$ROOT"/}." >&2; exit 2; }
	CEILING="$(rg -N -e '^[0-9]+$' "$f" 2>/dev/null | head -1)"
	case "$CEILING" in
		"" | *[!0-9]*) echo "check_gdscript_budget: ${f#"$ROOT"/} carries no number." >&2; exit 2 ;;
	esac
}

files="$(rg --files -g '*.gd' "$SIM" 2>/dev/null)"
[ -n "$files" ] || { echo "check_gdscript_budget: no .gd under $SIM. A gate that examines nothing is not a gate." >&2; exit 2; }

lines="$(printf '%s\n' "$files" | tr '\n' '\0' | xargs -0 wc -l | tail -1 | awk '{print $1}')"
loops="$(rg -c --no-heading -g '*.gd' -e "$LOOP_RE" "$SIM" 2>/dev/null | awk -F: '{s+=$2} END {print s+0}')"

read_ceiling "$LINES_CEIL_FILE"; lines_ceil="$CEILING"
read_ceiling "$LOOPS_CEIL_FILE"; loops_ceil="$CEILING"

fail=0
judge() {  # judge <label> <have> <ceiling> <ceiling file> <what a rise means>
	local label="$1" have="$2" ceil="$3" file="$4" meaning="$5"
	if [ "$have" -gt "$ceil" ]; then
		echo "check_gdscript_budget: $label rose to $have against a ceiling of $ceil." >&2
		echo "                       $meaning" >&2
		fail=1
	elif [ "$have" -lt "$ceil" ]; then
		echo "check_gdscript_budget: $label is $have and ${file#"$ROOT"/} still says $ceil." >&2
		echo "                       A ratchet that is not tightened is not a ratchet. Write $have into it." >&2
		fail=1
	fi
}

judge "GDScript lines under sim/" "$lines" "$lines_ceil" "$LINES_CEIL_FILE" \
	"Work belongs on the GPU, or in the GDExtension when it is genuinely serial."
judge "cell-bounded loops under sim/" "$loops" "$loops_ceil" "$LOOPS_CEIL_FILE" \
	"A loop over cells in GDScript is a GPU reduction run in an interpreter."

[ "$fail" -eq 0 ] || exit 1
echo "check_gdscript_budget: OK ($lines lines, $loops cell loops, both at their ceilings)"
