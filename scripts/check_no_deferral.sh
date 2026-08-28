#!/usr/bin/env bash
# DEFERRAL CANNOT BE WRITTEN DOWN. A defect met is fixed; the words that record leaving one — in a commit
# message, HANDOFF.md, or a physics/performance tracker — fail the build. Pass a file (a commit message)
# to check it alone; with no argument the trackers are checked.
# EXIT 0 clean · 1 a deferral phrase · 2 cannot run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh"
require_tool rg
PHRASES='within the ceiling|pre-?existing|for now|left (as|it|this|them) |not my lane|another lane owns|out of scope|known issue|work-?around|deferred|later lane|next lane|accepted (as|within)|good enough'
if [ $# -ge 1 ]; then
	[ -f "$1" ] || { echo "check_no_deferral: no such file $1" >&2; exit 2; }
	TARGETS=("$1")
else
	TARGETS=("$ROOT/HANDOFF.md" "$ROOT/docs/PHYSICS_TODO.md" "$ROOT/docs/PERFORMANCE_TODO.md")
	for t in "${TARGETS[@]}"; do [ -f "$t" ] || { echo "check_no_deferral: MISSING $t" >&2; exit 2; }; done
fi
hits="$(rg -n -i -e "$PHRASES" "${TARGETS[@]}" | rg -v '^\s*#' || true)"
if [ -n "$hits" ]; then
	echo "check_no_deferral: FAILED — a defect is being left, in writing:" >&2
	printf '%s\n' "$hits" | sed 's/^/  /' >&2
	echo "Fix it, or state the symptom and the command that reproduces it, never that it waits." >&2
	exit 1
fi
echo "check_no_deferral: OK (${#TARGETS[@]} file(s), no deferral written down)"
