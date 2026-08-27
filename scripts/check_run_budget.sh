#!/usr/bin/env bash
# A VERIFICATION ARM IS SHORT. A run over docs/RUN_TIMEOUT_CEILING must carry `# SOAK: <why>` on the line
# before it, which marks it as one nobody blocks on.
#
# EXIT 0 clean · 1 an undeclared long run, or a ceiling left above the real maximum · 2 could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh" 2>/dev/null || true
require_tool rg

CEIL_FILE="$ROOT/docs/RUN_TIMEOUT_CEILING"
[ -f "$CEIL_FILE" ] || { echo "check_run_budget: no ceiling at docs/RUN_TIMEOUT_CEILING." >&2; exit 2; }
CEIL="$(rg -N -e '^[0-9]+$' "$CEIL_FILE" 2>/dev/null | head -1)"
case "$CEIL" in "" | *[!0-9]*) echo "check_run_budget: the ceiling carries no number." >&2; exit 2 ;; esac

[ -d "$ROOT/scripts" ] || { echo "check_run_budget: MISSING $ROOT/scripts" >&2; exit 2; }

# EVERY WAY A SCRIPT SETS THE TIME IT WILL WAIT FOR AN ENGINE RUN. Scanning only the `:-N` default form
# left an explicit LA_GODOT_TIMEOUT=300 unread, so the gate could not fail on the two longest waits in the
# tree. Lock waits are a different quantity — how long another lane's run may hold the machine — and are
# not run budgets, so they stay out.
BUDGET_RE='(LA_RUN_TIMEOUT|LA_GODOT_TIMEOUT)(:-[0-9]+|=[0-9]+|="?\$\{[A-Z_]+:-[0-9]+)'
hits="$(rg -n --no-heading -o -e "$BUDGET_RE" "$ROOT/scripts" 2>/dev/null || true)"
[ -n "$hits" ] || { echo "check_run_budget: no run budget anywhere. The runner lost its budget." >&2; exit 2; }

# file:line:match -> seconds, or nothing when the line is a comment showing how to raise it.
budget() {
	local file="${1%%:*}" rest="${1#*:}" lno m src
	lno="${rest%%:*}"
	m="${rest#*:}"
	src="$(sed -n "${lno}p" "$file" 2>/dev/null)"
	case "$src" in [[:space:]]*\#* | \#*) return 1 ;; esac
	printf '%s' "$m" | sed -E 's/.*[^0-9]([0-9]+)$/\1/'
	printf '%s\n' "$file:$lno" > /dev/null
}

fail=0
worst=0
while IFS= read -r line; do
	[ -n "$line" ] || continue
	file="${line%%:*}"; rest="${line#*:}"
	lno="${rest%%:*}"
	val="$(budget "$line")" || continue
	[ -n "$val" ] || continue
	[ "$val" -gt "$worst" ] && worst="$val"
	[ "$val" -le "$CEIL" ] && continue
	# A soak declares itself on the line above.
	prev="$(sed -n "$((lno - 1))p" "$file" 2>/dev/null)"
	case "$prev" in
		*"# SOAK:"*) continue ;;
	esac
	echo "check_run_budget: ${file#"$ROOT"/}:$lno waits ${val}s against a ceiling of ${CEIL}s, undeclared." >&2
	echo "                  Shorten it, or mark the line above '# SOAK: <why nobody blocks on this>'." >&2
	fail=1
done <<< "$hits"

# The ratchet half: an undeclared maximum below the ceiling means the ceiling comes down.
if [ "$fail" -eq 0 ]; then
	declared_max=0
	while IFS= read -r line; do
		[ -n "$line" ] || continue
		file="${line%%:*}"; rest="${line#*:}"
		lno="${rest%%:*}"
		val="$(budget "$line")" || continue
		[ -n "$val" ] || continue
		prev="$(sed -n "$((lno - 1))p" "$file" 2>/dev/null)"
		case "$prev" in *"# SOAK:"*) continue ;; esac
		[ "$val" -gt "$declared_max" ] && declared_max="$val"
	done <<< "$hits"
	if [ "$declared_max" -gt 0 ] && [ "$declared_max" -lt "$CEIL" ]; then
		echo "check_run_budget: the longest undeclared run is ${declared_max}s and the ceiling says ${CEIL}s." >&2
		echo "                  A ratchet that is not tightened is not a ratchet. Write ${declared_max} into it." >&2
		fail=1
	fi
fi

[ "$fail" -eq 0 ] || exit 1
echo "check_run_budget: OK (ceiling ${CEIL}s; longest run seen ${worst}s)"
