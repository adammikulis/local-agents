#!/usr/bin/env bash
# Capture and gate wall durations, added up, less the seconds this runner scope
# spent queued behind another lane on the machine locks — a budget that counted the queue would read how
# busy the machine was, not what this tree costs to verify. Against docs/LINT_SECONDS_CEILING, a ratchet:
# write the number it fell to, never raise it to turn a light green.
# EXIT 0 at or under the ceiling · 1 over it · 2 nothing was timed.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

CEIL_FILE="$ROOT/docs/LINT_SECONDS_CEILING"
[ -f "$CEIL_FILE" ] || { echo "check_lint_budget: no docs/LINT_SECONDS_CEILING." >&2; exit 2; }
CEIL="$(grep -m1 -E '^[0-9]+$' "$CEIL_FILE")"
case "$CEIL" in
	"" | *[!0-9]*) echo "check_lint_budget: the ceiling carries no number." >&2; exit 2 ;;
esac
# 0 IS NOT A CEILING OF ZERO. It is a ratchet no full lint has banked yet, and a gate weighing a lint
# against nothing has examined nothing: scripts/write_ceilings.sh sets it from the newest lint's own line.


TIMING="${LA_LINT_TIMING_LOG:-}"
if [ -z "$TIMING" ] || [ ! -f "$TIMING" ]; then
	echo "check_lint_budget: no LA_LINT_TIMING_LOG, so no gate was timed and this examined nothing." >&2
	echo "                   Run it through scripts/agent_harness.sh lint, which opens one." >&2
	exit 2
fi
if ! grep -q 'LA_LINT_TIMING_LOG' "$ROOT/scripts/gate_runner.py"; then
	echo "check_lint_budget: gate_runner.py no longer writes LA_LINT_TIMING_LOG, so no sum is truthful." >&2
	exit 2
fi
if ! grep -q 'LA_LOCK_WAIT_LOG' "$ROOT/scripts/lib_godot_lock.sh"; then
	echo "check_lint_budget: lib_godot_lock.sh no longer publishes what it waited, so the queue cannot" >&2
	echo "                   be told from the work." >&2
	exit 2
fi

GATES="$(grep -c . "$TIMING" | tr -d ' ')"
if [ "$GATES" -lt 2 ]; then
	echo "check_lint_budget: the run timed $GATES gate(s), so there is no lint here to weigh." >&2
	exit 2
fi
SPENT="$(awk -F'\t' '{s += $1} END {printf "%.3f", s + 0}' "$TIMING")"
QUEUED="$(awk -F'\t' '{s += $1} END {printf "%.3f", s + 0}' "${LA_LOCK_WAIT_LOG:-/dev/null}" 2>/dev/null)"
[ -n "$QUEUED" ] || QUEUED=0
OWN="$(awk -v a="$SPENT" -v b="$QUEUED" 'BEGIN{v = a - b; printf "%.3f", (v > 0 ? v : 0)}')"

echo "LINT_BUDGET={\"gates\":$GATES,\"wall_s\":$SPENT,\"queued_s\":$QUEUED,\"own_s\":$OWN,\"ceiling_s\":$CEIL}"
if [ "$CEIL" = "0" ]; then
	echo "LINT_NOT_EXAMINED: check_lint_budget.sh — docs/LINT_SECONDS_CEILING is unbanked"
	exit 3
fi
if awk -v o="$OWN" -v c="$CEIL" 'BEGIN{exit !(o <= c)}'; then
	echo "check_lint_budget: OK ($OWN s of own work, ceiling $CEIL)"
	exit 0
fi
echo >&2
echo "This lint spent $OWN s of its own work, past docs/LINT_SECONDS_CEILING of $CEIL. The landing loop" >&2
echo "is one lint per landing, so this is the cost of every change. Cut a launch, share the capture, or" >&2
echo "cut an arm's frames to the fewest that prove its claim. The slowest gates:" >&2
sort -rn "$TIMING" | head -12 >&2
exit 1
