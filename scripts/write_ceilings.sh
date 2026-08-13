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
. "$SCRIPT_DIR/lib_ceiling.sh" 2>/dev/null || true
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
LOOP_RE="$(cell_loop_re)"
loops="$(rg -c --no-heading -g '*.gd' -e "$LOOP_RE" "$SIM" 2>/dev/null | awk -F: '{s+=$2} END {print s+0}')"
lower GDSCRIPT_LINES_CEILING "$lines"
lower CELL_LOOP_CEILING "$loops"

# Every remaining count comes from its own gate, which is the only thing that knows how it counts.
#
# READ THE UNCONDITIONAL MACHINE LINE, NEVER A PROSE FAILURE MESSAGE. This read `^COPIES: <n>` — a line
# check_duplicate_logic.sh prints only when the count is OVER the ceiling or when LA_DUP_STRICT=1, and the
# call below set it to 0. So the grep matched nothing, `lower` was never reached, and the three duplicate
# ceilings could not be tightened by anything. Same shape for the two comment ceilings, which were absent
# from this file entirely.
field() {  # field <json line> <key>
	printf '%s\n' "$1" | rg -N -o -e "\"$2\":[0-9]+" | head -1 | rg -N -o -e '[0-9]+' || true
}

dup="$(cd "$TREE" && bash scripts/check_duplicate_logic.sh 2>&1 | rg -N '^DUPLICATE_LOGIC=' || true)"
[ -n "$dup" ] || { echo "write_ceilings: check_duplicate_logic.sh printed no DUPLICATE_LOGIC= line." >&2; exit 2; }
lower DUPLICATE_LOGIC_CEILING "$(field "$dup" redundant_copies)"
lower DUPLICATE_SHAPE_CEILING "$(field "$dup" shape_copies)"
lower DUPLICATE_FRAGMENT_CEILING "$(field "$dup" fragment_copies)"

claims="$(cd "$TREE" && bash scripts/check_comment_claims.sh 2>&1 | rg -N '^COMMENT_CLAIMS=' || true)"
[ -n "$claims" ] || { echo "write_ceilings: check_comment_claims.sh printed no COMMENT_CLAIMS= line." >&2; exit 2; }
lower COMMENT_CLAIMS_CEILING "$(field "$claims" count)"

hist="$(cd "$TREE" && bash scripts/check_comment_history.sh 2>&1 | rg -N '^COMMENT_HISTORY=' || true)"
[ -n "$hist" ] || { echo "write_ceilings: check_comment_history.sh printed no COMMENT_HISTORY= line." >&2; exit 2; }
lower COMMENT_HISTORY_CEILING "$(field "$hist" count)"

[ "$fail" -eq 0 ] || exit 1
