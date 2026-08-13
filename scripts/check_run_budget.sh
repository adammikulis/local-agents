#!/usr/bin/env bash
# A VERIFICATION ARM IS SHORT. A long run is a SOAK, it is declared as one, and it is never what a lane
# waits on to know whether its change is good.
#
# run_sim_offscreen.sh already defaults LA_RUN_TIMEOUT to 60s and its own comment says to raise it only for
# a deliberate soak. Every caller above it then overrode that -- sim_run.sh to 900, check_conservation.sh
# to 1800 -- so the discipline held at the bottom layer and nowhere else, and the routine acceptance arm
# every lane runs could sit for fifteen minutes before saying anything.
#
# A run over the ceiling must carry `# SOAK: <why>` on the line before it. That is not a rubber stamp: it
# marks the run as one nobody blocks on, and it makes the long ones countable.
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

# Every declared default, as file:line:seconds.
hits="$(rg -n --no-heading -o -e 'LA_RUN_TIMEOUT:-[0-9]+' "$ROOT/scripts" 2>/dev/null || true)"
[ -n "$hits" ] || { echo "check_run_budget: no LA_RUN_TIMEOUT default anywhere. The runner lost its budget." >&2; exit 2; }

fail=0
worst=0
while IFS= read -r line; do
	[ -n "$line" ] || continue
	file="${line%%:*}"; rest="${line#*:}"
	lno="${rest%%:*}"; val="${rest##*-}"
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
		lno="${rest%%:*}"; val="${rest##*-}"
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
