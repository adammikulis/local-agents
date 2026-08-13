#!/usr/bin/env bash
# HANDOFF.md is the next agent's instruction set, not a scratchpad. It gets the file and the expression.
# It does not get reasoning, retractions, what was first thought, what was ruled out, or what a run printed.
#
# EXIT 0 clean · 1 scratchpad prose · 2 the gate could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh" 2>/dev/null || true
command -v rg >/dev/null 2>&1 || { echo "check_doc_prose: rg absent." >&2; exit 2; }

TARGETS=()
for d in HANDOFF.md docs/PHYSICS_TODO.md; do
	[ -f "$ROOT/$d" ] && TARGETS+=("$ROOT/$d")
done
[ "${#TARGETS[@]}" -gt 0 ] || { echo "check_doc_prose: no target doc." >&2; exit 2; }

# First person is the tell: a map has no narrator.
BANNED='\b(I |I'"'"'|my |we |our |me\b)|\bcorrected\b|\bfalsified\b|\bre-derived it\b|changes the diagnosis|reframes it|first reading|turns out|it seems|I thought|ruled out'

hits="$(rg -n --no-heading -i -e "$BANNED" "${TARGETS[@]}" 2>/dev/null || true)"
if [ -n "$hits" ]; then
	echo "check_doc_prose: scratchpad prose in the map." >&2
	printf '%s\n' "$hits" | sed 's/^/  /' >&2
	echo "" >&2
	echo "Name the file and the expression. Delete the reasoning. Nobody needs your working." >&2
	exit 1
fi
# NO CHANGELOGS. The tree is the change log. A hand-written one is a second account of what happened,
# it drifts from the first the day it is written, and it is always the wrong one.
banned_files="$(cd "$ROOT" && git ls-files 2>/dev/null | rg -i '(^|/)(changelog|release[_-]?notes|whats[_-]?new|history)\.(md|txt|rst)$' || true)"
if [ -n "$banned_files" ]; then
	echo "check_doc_prose: a changelog is tracked. The tree is the change log." >&2
	printf '%s\n' "$banned_files" | sed 's/^/  /' >&2
	exit 1
fi
# HANDOFF.md IS AN INSTRUCTION SET, SO IT HAS NO PAST TENSE AT ALL. The narrator ban above catches a
# writer talking about themselves; these catch the other half, a map that has started keeping records --
# a settled list, a struck claim, a dated finding, a section of what turned out to be false. Every one of
# those is a second account of the tree that disagrees with the tree, and a reader cannot tell which half
# still holds. `docs/PHYSICS_TODO.md` is exempt: an open physics item legitimately says when it was
# measured and what a struck claim used to assert.
# Its ABSENCE is exit 2, never a pass. The rules below are all "HANDOFF.md must not contain X", and a rule
# of that shape is satisfied by the file not existing -- which is how a gate comes to report OK on a map
# somebody deleted.
HANDOFF="$ROOT/HANDOFF.md"
[ -f "$HANDOFF" ] || { echo "check_doc_prose: no HANDOFF.md. The map is not optional." >&2; exit 2; }
if true; then
	MAX_MAP_LINES=200
	n="$(wc -l < "$HANDOFF" | tr -d ' ')"
	if [ "$n" -gt "$MAX_MAP_LINES" ]; then
		echo "check_doc_prose: HANDOFF.md is $n lines against a ceiling of $MAX_MAP_LINES." >&2
		echo "A list nobody reads to the bottom of is where stale instructions live. Delete what landed." >&2
		exit 1
	fi
	map_hits="$(rg -n --no-heading \
		-e '\b20[0-9]{2}\b' \
		-e '~~' \
		-e '(?i)^#+.*\b(settled|found by|dead or lying|struck|what is left|state|history|done)\b' \
		-e '(?i)\b(do not re-derive|claims struck|was FALSE|stale|outlived it)\b' \
		"$HANDOFF" 2>/dev/null || true)"
	if [ -n "$map_hits" ]; then
		echo "check_doc_prose: HANDOFF.md is keeping records. It is an instruction set." >&2
		printf '%s\n' "$map_hits" | sed 's/^/  /' >&2
		echo "" >&2
		echo "No dates, no strikethroughs, no settled list, no struck claims. Say what to do next." >&2
		exit 1
	fi
fi
echo "check_doc_prose: OK (${#TARGETS[@]} doc(s), no narrator, no changelog, the map has no past tense)"
