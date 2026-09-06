#!/usr/bin/env bash
# A GATE NOBODY RUNS ASSERTS NOTHING. scripts/gates.toml is the one list the runner walks, so a
# scripts/check_*.sh in no [[gate]] row that no OTHER script names is a claim written down and never read.
# The count is a RATCHET in docs/UNREGISTERED_GATE_CEILING: it may fall and may not rise, so a gate added
# tomorrow is registered the same day.
# EXIT 0 the count is at or under the ceiling · 1 it rose · 2 the gate could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh"
require_tool rg

LIST="$ROOT/scripts/gates.toml"
CEIL="$ROOT/docs/UNREGISTERED_GATE_CEILING"
[ -f "$LIST" ] || { echo "check_gate_registered: MISSING scripts/gates.toml" >&2; exit 2; }
[ -f "$CEIL" ] || { echo "check_gate_registered: MISSING docs/UNREGISTERED_GATE_CEILING" >&2; exit 2; }
CAP="$(grep -v '^#' "$CEIL" | tr -d '[:space:]')"
printf '%s' "$CAP" | grep -Eq '^[0-9]+$' || {
	echo "check_gate_registered: docs/UNREGISTERED_GATE_CEILING holds no count." >&2; exit 2; }

registered="$(rg -N -o '^script = "scripts/([a-z0-9_]+)\.sh"' -r '$1' "$LIST" | sort -u)"
[ -n "$registered" ] || { echo "check_gate_registered: gates.toml names no script." >&2; exit 2; }

# Every check_* a script other than itself names: the ladder walks the rung gates, and a gate may drive
# another. `-H` and the basename keep the mention and the mentioner side by side.
mentions="$(rg -N -H -o -e 'check_[a-z0-9_]+' "$ROOT"/scripts/*.sh 2>/dev/null \
	| sed 's|^.*/||' | awk -F: '$1 != $2 ".sh" { print $2 }' | sort -u)"

orphans=""
n=0
for f in "$ROOT"/scripts/check_*.sh; do
	b="${f##*/}"; b="${b%.sh}"
	printf '%s\n' "$registered" | grep -qx "$b" && continue
	printf '%s\n' "$mentions" | grep -qx "$b" && continue
	orphans="$orphans  $b.sh
"
	n=$((n + 1))
done

echo "UNREGISTERED_GATES={\"count\":$n,\"ceiling\":$CAP}"
if [ "$n" -gt "$CAP" ]; then
	echo "check_gate_registered: $n gate(s) are in no [[gate]] row and no script runs them, against a" >&2
	echo "                       ceiling of $CAP:" >&2
	printf '%s' "$orphans" >&2
	echo "Register it in scripts/gates.toml, or delete the claim nobody checks." >&2
	exit 1
fi
echo "check_gate_registered: OK ($n unregistered, ceiling $CAP)"
