#!/usr/bin/env bash
# GDSCRIPT IS THE BUDGET: the substrate runs on the GPU, what cannot goes to C++, and what is left is
# bindings. Two ratchets over addons/local_agents/sim -- total lines, and loops bounded by a cell count.
#
# EXIT 0 clean · 1 a ceiling breached, or a ceiling left standing above the real count · 2 could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh" 2>/dev/null || true
. "$ROOT/scripts/lib_ceiling.sh" 2>/dev/null || true
require_tool rg
require_tool wc

SIM="$ROOT/addons/local_agents/sim"
[ -d "$SIM" ] || { echo "check_gdscript_budget: MISSING $SIM" >&2; exit 2; }

LINES_CEIL_FILE="$ROOT/docs/GDSCRIPT_LINES_CEILING"
LOOPS_CEIL_FILE="$ROOT/docs/CELL_LOOP_CEILING"

# Declared once, in scripts/lib_ceiling.sh, because scripts/write_ceilings.sh must ask the identical
# question. Two copies of it meant the gate and the writer could disagree about what a cell loop is.
LOOP_RE="$(cell_loop_re)"

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

STRICT="$(ceiling_strict "$ROOT")"
read_ceiling "$LINES_CEIL_FILE"; lines_ceil="$CEILING"
read_ceiling "$LOOPS_CEIL_FILE"; loops_ceil="$CEILING"

fail=0
judge() {  # judge <label> <have> <ceiling> <ceiling file> <what a rise means>
	local label="$1" have="$2" ceil="$3" file="$4" meaning="$5"
	if [ "$have" -gt "$ceil" ]; then
		echo "check_gdscript_budget: $label rose to $have against a ceiling of $ceil." >&2
		echo "                       $meaning" >&2
		fail=1
	elif [ "$have" -lt "$ceil" ] && [ "$STRICT" = "1" ]; then
		echo "check_gdscript_budget: $label is $have and ${file#"$ROOT"/} still says $ceil." >&2
		echo "                       A ratchet that is not tightened is not a ratchet. Write $have into it," >&2
		echo "                       or land through scripts/integrate.sh, which writes it for you." >&2
		fail=1
	fi
}

judge "GDScript lines under sim/" "$lines" "$lines_ceil" "$LINES_CEIL_FILE" \
	"Work belongs on the GPU, or in the GDExtension when it is genuinely serial."
judge "cell-bounded loops under sim/" "$loops" "$loops_ceil" "$LOOPS_CEIL_FILE" \
	"A loop over cells in GDScript is a GPU reduction run in an interpreter."

[ "$fail" -eq 0 ] || exit 1
echo "check_gdscript_budget: OK ($lines lines, $loops cell loops; strict=$STRICT)"
