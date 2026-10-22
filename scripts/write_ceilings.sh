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
track() {  # track <floor file> <measured>: the floor follows the count it floors, either way
	local f="$TREE/docs/$1" have="$2"
	[ -f "$f" ] || { echo "write_ceilings: no docs/$1" >&2; exit 2; }
	local cur
	cur="$(rg -N -e '^[0-9]+$' "$f" | head -1)"
	case "$cur" in "" | *[!0-9]*) echo "write_ceilings: docs/$1 carries no number." >&2; exit 2 ;; esac
	if [ "$have" != "$cur" ]; then
		echo "write_ceilings: $1 $cur -> $have"
		sed -i '' "s/^$cur\$/$have/" "$f"
	fi
}

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

# THE COST RATCHETS COME OFF A LINT, and a lint is what runs AFTER this. So they are banked from the
# newest lint log that carries the line: one landing behind, and a ratchet only ever falls.
# $1 ceiling file · $2 marker · $3 json key · $4 scale to whole units
bank_from_lint() {
	local dir line val log
	dir="${LOG_DIR:-${TMPDIR:-/tmp}/local-agents-harness-logs}"
	line=""
	# THIS TREE'S OWN LINT. LOG_DIR is machine-wide and every lane writes into it.
	while IFS= read -r log; do
		grep -Fxq "LINT_TREE=$TREE" "$log" 2>/dev/null || continue
		grep -Fxq "LINT_BANKABLE=1" "$log" 2>/dev/null || continue
		line="$(rg -N -m1 -e "^$2=" "$log" 2>/dev/null || true)"
		[ -n "$line" ] && break
	done < <(ls -t "$dir"/agent_harness_lint_*.log 2>/dev/null)
	if [ -z "$line" ]; then
		echo "write_ceilings: no lint of $TREE carries $2, so docs/$1 stands." >&2
		return 0
	fi
	val="$(printf '%s\n' "$line" | rg -N -o "\"$3\":[0-9.]+" | rg -N -o '[0-9.]+' | head -1)"
	[ -n "$val" ] || { echo "write_ceilings: $2 carries no $3." >&2; return 0; }
	local have
	have="$(awk -v v="$val" -v s="$4" 'BEGIN{printf "%d", int(v * s) + (v * s > int(v * s))}')"
	# 0 IS UNBANKED, NOT A CEILING OF ZERO: the first full lint sets it, and every one after only lowers.
	if [ "$(rg -N -e '^[0-9]+$' "$TREE/docs/$1" | head -1)" = "0" ]; then
		perl -0pi -e "s/^0\$/$have/m" "$TREE/docs/$1"
		echo "write_ceilings: $1 banked at $have" >&2
		return 0
	fi
	lower "$1" "$have"
}

bank_from_lint LINT_SECONDS_CEILING LINT_BUDGET own_s 1
bank_from_lint FIELD_MS_CEILING FIELD_BUDGET worst_ms 1

bank_gate_seconds() {  # the newest passing lint of this tree lowers docs/GATE_SECONDS, which only falls
	local dir log
	dir="${LOG_DIR:-${TMPDIR:-/tmp}/local-agents-harness-logs}"
	while IFS= read -r log; do
		grep -Fxq "LINT_TREE=$TREE" "$log" 2>/dev/null || continue
		grep -Eq '^All [a-z]+-tier lint gates passed' "$log" 2>/dev/null || continue
		python3 "$TREE/scripts/gate_runner.py" --bank-seconds "$log" >&2 && return 0
	done < <(ls -t "$dir"/agent_harness_lint_*.log 2>/dev/null)
	echo "write_ceilings: no passing lint of $TREE, so docs/GATE_SECONDS stands." >&2
}
bank_gate_seconds

SIM="$TREE/addons/local_agents/sim"
[ -d "$SIM" ] || { echo "write_ceilings: no $SIM" >&2; exit 2; }
lines="$(gdscript_code_lines "$SIM")"
LOOP_RE="$(cell_loop_re)"
loops="$(rg -c --no-heading -g '*.gd' -e "$LOOP_RE" "$SIM" 2>/dev/null | awk -F: '{s+=$2} END {print s+0}')"
lower GDSCRIPT_LINES_CEILING "$lines"
lower CELL_LOOP_CEILING "$loops"

shims="$("$TREE/scripts/check_no_shim.sh" 2>&1 | rg -N -o '"count":[0-9]+' | rg -N -o '[0-9]+' | head -1)"
[ -n "$shims" ] || { echo "write_ceilings: check_no_shim reported no count." >&2; exit 2; }
lower SHIM_CEILING "$shims"

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

tiers="$(cd "$TREE" && bash scripts/check_gate_tiers.sh 2>&1 | rg -N '^SLOW_GATES_WITHOUT_INPUTS=' || true)"
[ -n "$tiers" ] || { echo "write_ceilings: check_gate_tiers.sh printed no SLOW_GATES_WITHOUT_INPUTS= line." >&2; exit 2; }
lower SLOW_GATES_WITHOUT_INPUTS_CEILING "$(field "$tiers" count)"

hist="$(cd "$TREE" && bash scripts/check_comment_history.sh 2>&1 | rg -N '^COMMENT_HISTORY=' || true)"
[ -n "$hist" ] || { echo "write_ceilings: check_comment_history.sh printed no COMMENT_HISTORY= line." >&2; exit 2; }
lower COMMENT_HISTORY_CEILING "$(field "$hist" count)"

inv="$(cd "$TREE" && bash scripts/check_no_invented_fallback.sh 2>&1 | rg -N '^INVENTED_QUERIES=' || true)"
[ -n "$inv" ] || { echo "write_ceilings: check_no_invented_fallback.sh printed no INVENTED_QUERIES= line." >&2; exit 2; }
lower INVENTED_QUERY_CEILING "$(field "$inv" count)"

wos="$(cd "$TREE" && bash scripts/check_write_only_state.sh 2>&1 | rg -N '^WRITE_ONLY_STATE=' || true)"
[ -n "$wos" ] || { echo "write_ceilings: check_write_only_state.sh printed no WRITE_ONLY_STATE= line." >&2; exit 2; }
lower WRITE_ONLY_STATE_CEILING "$(field "$wos" count)"

blk="$(cd "$TREE" && bash scripts/check_comment_block.sh 2>&1 | rg -N '^COMMENT_BLOCK=' || true)"
[ -n "$blk" ] || { echo "write_ceilings: check_comment_block.sh printed no COMMENT_BLOCK= line." >&2; exit 2; }
lower COMMENT_BLOCK_CEILING "$(field "$blk" count)"

pres="$(cd "$TREE" && bash scripts/check_presentation_in_sim.sh 2>&1 | rg -N '^PRESENTATION_IN_SIM=' || true)"
[ -n "$pres" ] || { echo "write_ceilings: check_presentation_in_sim.sh printed no PRESENTATION_IN_SIM= line." >&2; exit 2; }
lower PRESENTATION_IN_SIM_CEILING "$(field "$pres" count)"

mp="$(cd "$TREE" && bash scripts/check_model_parameters.sh 2>&1 | rg -N '^MODEL_PARAMETERS=' || true)"
[ -n "$mp" ] || { echo "write_ceilings: check_model_parameters.sh printed no MODEL_PARAMETERS= line." >&2; exit 2; }
mp_have="$(field "$mp" declared)"
mp_cur="$(field "$mp" ceiling)"
if [ "$mp_have" -gt "$mp_cur" ]; then
	echo "write_ceilings: MAX_DECLARED would RISE $mp_cur -> $mp_have. Refusing; fix the tree." >&2
	fail=1
elif [ "$mp_have" -lt "$mp_cur" ]; then
	perl -pi -e "s/MAX_DECLARED: $mp_cur\\b/MAX_DECLARED: $mp_have/" "$TREE/docs/MODEL_PARAMETERS.md"
	echo "write_ceilings: MAX_DECLARED $mp_cur -> $mp_have" >&2
fi

# Uncited values in the authority files, which check_model_parameters.sh exempts from its own registry.
# READ THE MACHINE LINES, not a prose message: the gate prints both counts unconditionally, pass or fail.
cited="$(cd "$TREE" && bash scripts/check_cited_authority.sh 2>&1 || true)"
au="$(printf '%s\n' "$cited" | rg -N '^UNCITED_AUTHORITY=' | head -1)"
lt="$(printf '%s\n' "$cited" | rg -N '^UNCITED_LITERALS=' | head -1)"
[ -n "$au" ] || { echo "write_ceilings: check_cited_authority.sh printed no UNCITED_AUTHORITY= line." >&2; exit 2; }
[ -n "$lt" ] || { echo "write_ceilings: check_cited_authority.sh printed no UNCITED_LITERALS= line." >&2; exit 2; }
lower UNCITED_AUTHORITY_CEILING "$(field "$au" count)"
lower UNCITED_LITERAL_CEILING "$(field "$lt" count)"

# A FLOOR, not a ceiling, and it moves the same way: down, and only here. It guards check_shaders_compile.sh
# against scanning a tree whose kernels did not import, so it tracks the kernel count rather than leading it.
kernels="$(rg --files -g '*.glsl' "$TREE/addons/local_agents/sim/material/kernels3d" 2>/dev/null | rg -c '.' || echo 0)"
[ "$kernels" -gt 0 ] || { echo "write_ceilings: found no .glsl kernels to floor." >&2; exit 2; }
track SHADER_FLOOR "$kernels"

[ "$fail" -eq 0 ] || exit 1
