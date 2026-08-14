#!/usr/bin/env bash
# A comment says what the code does and in what units. Why it changed belongs in `git log`, which the act
# itself writes and which cannot drift. CLAUDE.md bans the rest; this counts it.
#
# EXIT 0 clean · 1 a comment tells a story · 2 could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh" 2>/dev/null || true
# The SLACK arm belongs to the integrator; a lane fails only on a rise. See scripts/lib_ceiling.sh.
. "$ROOT/scripts/lib_ceiling.sh" 2>/dev/null || true
require_tool rg

SCAN=("$ROOT/scripts" "$ROOT/addons/local_agents")
for d in "${SCAN[@]}"; do
	[ -d "$d" ] || { echo "check_comment_history: MISSING $d" >&2; exit 2; }
done

CEIL_FILE="$ROOT/docs/COMMENT_HISTORY_CEILING"
[ -f "$CEIL_FILE" ] || { echo "check_comment_history: no docs/COMMENT_HISTORY_CEILING." >&2; exit 2; }
CEIL="$(rg -N -e '^[0-9]+$' "$CEIL_FILE" | head -1)"
case "$CEIL" in "" | *[!0-9]*) echo "check_comment_history: the ceiling carries no number." >&2; exit 2 ;; esac

# A comment line only. The tells of a story: a date, a session, a count of times, a past-tense report.
# A LITERATURE CITATION IS NOT A STORY: CLAUDE.md requires one beside a physical constant.
TELL='(^|\s)(#|//)\s*.*(\b20[0-9]{2}\b|\bmeasured\b|\bone session\b|\bthis session\b|\bused to\b|\bwas (once|nearly|already)\b|\bhad been\b|\bturned out\b|\bwent red\b|\bcost (a|us|the)\b|\bfour of six\b|\bthirty-four\b)'
# The year must be FOLLOWED by a comma or close paren, which `In 2026 this went red` is not.
CITE='([A-Z][A-Za-z.-]+|&)[[:space:]]+(19|20)[0-9]{2}[,)]|[0-9]+(st|nd|rd|th)[[:space:]]+ed\.'
hits="$(rg -n --no-heading -g '*.sh' -g '*.gd' -g '*.glsl' -g '*.glsli' -g '*.py' -e "$TELL" "${SCAN[@]}" 2>/dev/null \
	| rg -v -e "$CITE" || true)"
n="$(printf '%s' "$hits" | rg -c '.' || echo 0)"

# The count, unconditionally and machine-readable: scripts/write_ceilings.sh reads it from here, because
# only the gate knows how it counts. A number recoverable only from a prose failure message is a number
# the integrator cannot bank.
echo "COMMENT_HISTORY={\"count\":$n,\"cap\":$CEIL}"

if [ "$n" -gt "$CEIL" ]; then
	echo "check_comment_history: $n comment(s) tell a story, against a ceiling of $CEIL." >&2
	printf '%s\n' "$hits" | head -20 | sed 's/^/  /' >&2
	echo "" >&2
	echo "Say what the code does and in what units. git log holds why it changed." >&2
	exit 1
fi
if [ "$n" -lt "$CEIL" ] && [ "$(ceiling_strict "$ROOT")" = "1" ]; then
	echo "check_comment_history: $n and docs/COMMENT_HISTORY_CEILING says $CEIL. Write $n into it." >&2
	exit 1
fi
echo "check_comment_history: OK ($n against a ceiling of $CEIL)"
