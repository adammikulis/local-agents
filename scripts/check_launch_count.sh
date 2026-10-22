#!/usr/bin/env bash
# A LINT LAUNCHES THE ENGINE ONCE PER ARM IT ACTUALLY NEEDS, AND EVERY LAUNCH IS A WINDOW.
# lib_godot.sh appends one line per launch to LA_LAUNCH_LOG; agent_harness.sh lint opens one, so this
# counts what the lint around it did. docs/LAUNCH_CEILING is a ratchet: write the count it fell to,
# never raise it to turn a light green.
# EXIT 0 at or under the ceiling · 1 over it · 2 nothing was counted.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

CEIL_FILE="$ROOT/docs/LAUNCH_CEILING"
[ -f "$CEIL_FILE" ] || { echo "check_launch_count: no docs/LAUNCH_CEILING." >&2; exit 2; }
CEIL="$(grep -m1 -E '^[0-9]+$' "$CEIL_FILE")"
case "$CEIL" in
	"" | *[!0-9]*) echo "check_launch_count: the ceiling carries no number." >&2; exit 2 ;;
esac

# THE RUN'S LEDGER, NOT THIS GATE'S. gate_runner.py hands every gate its own LA_LAUNCH_LOG for
# attribution and folds each into the run's; reading its own would count nothing but itself, for ever.
LOG="${LA_LINT_LAUNCHES:-}"
if [ -z "$LOG" ] || [ ! -f "$LOG" ]; then
	echo "check_launch_count: no LA_LINT_LAUNCHES, so no launch was counted and this examined nothing." >&2
	echo "                    Run it through scripts/agent_harness.sh lint, which opens one." >&2
	exit 2
fi
# An EMPTY log is a count of zero, which is the best a lint can do: every arm came out of a cache. The
# writer is what must be proved live, not the number.
if ! grep -q 'LA_LAUNCH_LOG' "$ROOT/scripts/lib_godot.sh"; then
	echo "check_launch_count: lib_godot.sh no longer writes LA_LAUNCH_LOG, so no count is truthful." >&2
	exit 2
fi
# An import is cache state, not a gate's arm: reported, never counted against the roster.
I="$(grep -c -- '--import' "$LOG" | tr -d ' ')"
N="$(grep -v -- '--import' "$LOG" | grep -c . | tr -d ' ')"

echo "LAUNCH_COUNT={\"launches\":$N,\"imports\":$I,\"ceiling\":$CEIL}"
if [ "$N" -gt "$CEIL" ]; then
	echo "check_launch_count: this lint launched the engine $N time(s), past the ceiling of $CEIL." >&2
	echo "                    Read the shared capture (scripts/lint_capture.sh, LA_LINT_CAPTURE) rather" >&2
	echo "                    than starting another engine. The launches, most frequent first:" >&2
	sed -E 's/(-s |--path |--log-file )[^ ]*/\1<path>/g' "$LOG" | sort | uniq -c | sort -rn | head -12 >&2
	exit 1
fi
echo "check_launch_count: OK ($N launch(es), ceiling $CEIL)"
