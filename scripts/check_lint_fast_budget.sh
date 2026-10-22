#!/usr/bin/env bash
# THE FAST TIER STAYS FAST. The wall seconds of every fast-tier gate this run timed, added up, against
# docs/LINT_FAST_SECONDS_CEILING, a ratchet: write the number it fell to, never raise it to turn a light green.
# A gate that makes the tier slower than the ceiling fails here; the fix is a cheaper gate or a slow-tier row.
# EXIT 0 at or under the ceiling · 1 over it · 2 nothing was timed.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

CEIL_FILE="$ROOT/docs/LINT_FAST_SECONDS_CEILING"
[ -f "$CEIL_FILE" ] || { echo "check_lint_fast_budget: no docs/LINT_FAST_SECONDS_CEILING." >&2; exit 2; }
CEIL="$(grep -m1 -E '^[0-9]+$' "$CEIL_FILE")"
case "$CEIL" in
	"" | *[!0-9]*) echo "check_lint_fast_budget: the ceiling carries no number." >&2; exit 2 ;;
esac
[ "$CEIL" != "0" ] || { echo "check_lint_fast_budget: the ceiling is 0, which no tier meets." >&2; exit 2; }

TIMING="${LA_LINT_TIMING_LOG:-}"
if [ -z "$TIMING" ] || [ ! -f "$TIMING" ]; then
	echo "check_lint_fast_budget: no LA_LINT_TIMING_LOG, so no gate was timed and this examined nothing." >&2
	echo "                        Run it through scripts/agent_harness.sh lint, which opens one." >&2
	exit 2
fi
if ! grep -q 'LA_LINT_TIMING_LOG' "$ROOT/scripts/gate_runner.py"; then
	echo "check_lint_fast_budget: gate_runner.py no longer writes LA_LINT_TIMING_LOG, so no sum is truthful." >&2
	exit 2
fi

GATES="$(awk -F'\t' '$3 == "fast"' "$TIMING" | grep -c . | tr -d ' ')"
if [ "$GATES" -lt 2 ]; then
	echo "check_lint_fast_budget: the run timed $GATES fast gate(s), so there is no fast tier here to weigh." >&2
	exit 2
fi
SPENT="$(awk -F'\t' '$3 == "fast" {s += $1} END {printf "%.3f", s + 0}' "$TIMING")"

echo "LINT_FAST_BUDGET={\"gates\":$GATES,\"wall_s\":$SPENT,\"ceiling_s\":$CEIL}"
if awk -v o="$SPENT" -v c="$CEIL" 'BEGIN{exit !(o <= c)}'; then
	echo "check_lint_fast_budget: OK ($SPENT s across $GATES fast gate(s), ceiling $CEIL)"
	exit 0
fi
echo >&2
echo "The fast tier spent $SPENT s, past docs/LINT_FAST_SECONDS_CEILING of $CEIL. Every commit pays it. Make the" >&2
echo "slowest gate cheaper, or give it a slow-tier row (tier = \"slow\", with inputs). The slowest fast gates:" >&2
awk -F'\t' '$3 == "fast"' "$TIMING" | sort -rn | head -12 >&2
exit 1
