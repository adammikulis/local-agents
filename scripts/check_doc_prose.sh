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
echo "check_doc_prose: OK (${#TARGETS[@]} doc(s), no narrator, no changelog)"
