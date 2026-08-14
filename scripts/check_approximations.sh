#!/usr/bin/env bash
# A declared approximation is a promise that the SHAPE is real and the exact solver can swap in. A promise
# nobody checks is prose, and prose rots -- so the registry and the code are held to each other both ways.
#
# EXIT 0 clean · 1 a marker with no row, a row with no marker, or a row naming no replacement · 2 could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh" 2>/dev/null || true
command -v rg >/dev/null 2>&1 || { echo "check_approximations: rg absent." >&2; exit 2; }

REG="$ROOT/docs/APPROXIMATIONS.md"
SRC="$ROOT/addons/local_agents"
[ -f "$REG" ] || { echo "check_approximations: MISSING $REG. The registry is not optional." >&2; exit 2; }
[ -d "$SRC" ] || { echo "check_approximations: MISSING $SRC" >&2; exit 2; }

# Rows: | `key` | stands in for | what swaps it in |
rows="$(rg -N -o '^\| `([a-z0-9_]+)` \|' -r '$1' "$REG" 2>/dev/null | sort -u)"
[ -n "$rows" ] || { echo "check_approximations: the registry has no rows, so this gate examines nothing." >&2; exit 2; }

# Markers in code: LA_APPROX: <key>
marks="$(rg -N --no-filename -o 'LA_APPROX:[[:space:]]*([a-z0-9_]+)' -r '$1' "$SRC" 2>/dev/null | sort -u)"

fail=0
for k in $rows; do
	printf '%s\n' "$marks" | rg -qx "$k" || {
		echo "check_approximations: row '$k' is declared and NO code is marked with it." >&2
		echo "                     Either the approximation is gone (delete the row) or the site is unmarked." >&2
		fail=1
	}
	# The third column must say what replaces it; a row that promises no swap is a permanent departure.
	rg -N -q "^\| \`$k\` \|[^|]*\|[^|]*[A-Za-z][^|]*\|" "$REG" || {
		echo "check_approximations: row '$k' names no replacement. Condition 2 is that the real one swaps in." >&2
		fail=1
	}
done
for k in $marks; do
	printf '%s\n' "$rows" | rg -qx "$k" || {
		echo "check_approximations: code is marked LA_APPROX: $k and the registry has no such row." >&2
		echo "                     Declare it, with what it stands in for and what swaps it in." >&2
		fail=1
	}
done

[ "$fail" -eq 0 ] || exit 1
echo "check_approximations: OK ($(printf '%s\n' "$rows" | wc -l | tr -d ' ') declared, each marked and each with a replacement)"
