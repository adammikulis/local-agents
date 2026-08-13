#!/usr/bin/env bash
# WRITES THE RATCHET CEILINGS TO WHAT THE TREE ACTUALLY MEASURES. The integrator's half of
# scripts/lib_ceiling.sh: lanes never edit these files, so they never conflict over them.
#
# It only ever LOWERS. A count that rose is a lane making the tree worse, and the gate must fail on it
# rather than be papered over here.
#
# EXIT 0 wrote or had nothing to write · 1 a count ROSE, so nothing was written · 2 could not run.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TREE="${1:-$(cd "$SCRIPT_DIR/.." && pwd)}"
. "$SCRIPT_DIR/lib_require.sh" 2>/dev/null || true
require_tool rg

fail=0
lower() {  # lower <ceiling file> <measured>
	local f="$TREE/docs/$1" have="$2"
	[ -f "$f" ] || { echo "write_ceilings: no docs/$1" >&2; exit 2; }
	local cur
	cur="$(rg -N -e '^[0-9]+$' "$f" | head -1)"
	case "$cur" in "" | *[!0-9]*) echo "write_ceilings: docs/$1 carries no number." >&2; exit 2 ;; esac
	if [ "$have" -gt "$cur" ]; then
		echo "write_ceilings: $1 would RISE $cur -> $have. Refusing; fix the tree." >&2
		fail=1
		return
	fi
	[ "$have" -eq "$cur" ] && return
	perl -0pi -e "s/^$cur\$/$have/m" "$f"
	echo "write_ceilings: $1 $cur -> $have" >&2
}

SIM="$TREE/addons/local_agents/sim"
[ -d "$SIM" ] || { echo "write_ceilings: no $SIM" >&2; exit 2; }
lines="$(rg --files -g '*.gd' "$SIM" | tr '\n' '\0' | xargs -0 wc -l | tail -1 | awk '{print $1}')"
LOOP_RE='for [a-zA-Z_][a-zA-Z0-9_]* in (cc|_cc|cell_count|_cell_count|_f\._cell_count|[a-zA-Z_]*grid\.cell_count)\b|while [a-zA-Z_][a-zA-Z0-9_]* < (cc|_cc|cell_count|_cell_count|_f\._cell_count|[a-zA-Z_]*grid\.cell_count)\b'
loops="$(rg -c --no-heading -g '*.gd' -e "$LOOP_RE" "$SIM" 2>/dev/null | awk -F: '{s+=$2} END {print s+0}')"
lower GDSCRIPT_LINES_CEILING "$lines"
lower CELL_LOOP_CEILING "$loops"

# The duplicate counts come from the gate itself, which is the only thing that knows how it hashes.
out="$(cd "$TREE" && LA_DUP_STRICT=0 bash scripts/check_duplicate_logic.sh 2>&1 || true)"
for pair in "COPIES:DUPLICATE_LOGIC_CEILING" "SHAPE:DUPLICATE_SHAPE_CEILING" "FRAGMENT:DUPLICATE_FRAGMENT_CEILING"; do
	label="${pair%%:*}"; file="${pair##*:}"
	n="$(printf '%s\n' "$out" | rg -N -o -e "^$label: [0-9]+" | head -1 | rg -N -o -e '[0-9]+' || true)"
	[ -n "$n" ] && lower "$file" "$n"
done

[ "$fail" -eq 0 ] || exit 1
