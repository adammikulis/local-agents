#!/usr/bin/env bash
# No slot, index or table may mean "up". Direction comes from the solved gravity field.
#
# EXIT 0 clean · 1 a privileged axis · 2 the gate could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh" 2>/dev/null || true
command -v rg >/dev/null 2>&1 || { echo "check_no_privileged_axis: rg absent." >&2; exit 2; }
K="$ROOT/addons/local_agents/sim/material/kernels3d"
[ -d "$K" ] || { echo "check_no_privileged_axis: MISSING $K" >&2; exit 2; }

fail=0
report() {
	local what="$1"; shift
	local hits
	hits="$(rg -n --no-heading "$@" "$K" 2>/dev/null || true)"
	if [ -n "$hits" ]; then
		echo "check_no_privileged_axis: $what" >&2
		echo "$hits" | sed 's/^/  /' >&2
		fail=1
	fi
}

# A slot that names a direction. Opposite is d ^ 1; nothing else about a slot is meaningful.
report "a neighbour slot is named for a direction" -e '\bN_IN\b|\bN_OUT\b|\bN_LAT0\b|\bN_LATERAL_COUNT\b'

# Walking a column by array stride assumes the memory layout is the vertical.
report "a column is walked by array stride" -e '(\+|-)\s*params\.depth\b|%\s*params\.depth\b|/\s*params\.depth\b'

# The radial shell table: every spacing on a uniform grid is cell_size.
report "the radial shell table is read" -e '\bshell_dr\s*\(|\bshell_mid\s*\(|\bshell_face\s*\(|\bshell_d_out\s*\(|\bshell_d_in\s*\('

# An axis hardcoded as up.
report "an axis is hardcoded as up" -e 'vec3\(0\.0,\s*1\.0,\s*0\.0\)|\.y\s*>\s*0\.0\s*\)\s*//.*up'

if [ "$fail" -ne 0 ]; then
	echo >&2
	echo "Down is -normalize(g) read per cell, not an index. A column is a march along it." >&2
	exit 1
fi
echo "check_no_privileged_axis: OK"
