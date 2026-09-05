#!/usr/bin/env bash
# A GATE THAT CANNOT BE INVOKED IS NOT A GATE. A scripts/check_*.sh committed without the executable bit
# exits 126 "Permission denied" — neither 0, 1 nor 2 — so a caller reads it as neither pass nor failure.
# The mode is read out of the git index, not the working tree: a filesystem that drops it still ships.
# EXIT 0 every gate is executable · 1 one is not · 2 could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh" 2>/dev/null || true
require_tool git

listing="$(git -C "$ROOT" ls-files -s 'scripts/check_*.sh' 2>/dev/null)"
[ -n "$listing" ] || { echo "check_gate_executable: git listed no scripts/check_*.sh." >&2; exit 2; }

bad=0
while read -r mode _rest; do
	path="${_rest#*	}"
	[ -n "$path" ] || continue
	if [ "$mode" != "100755" ]; then
		echo "check_gate_executable: $path is mode $mode — it cannot be run as a command." >&2
		bad=$((bad + 1))
	fi
done <<< "$listing"

n="$(printf '%s\n' "$listing" | wc -l | tr -d ' ')"
if [ "$bad" -ne 0 ]; then
	echo "                       git update-index --chmod=+x <path>, and commit the mode." >&2
	exit 1
fi
echo "check_gate_executable: OK ($n gate script(s), every one executable)"
