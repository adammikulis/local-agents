#!/usr/bin/env bash
# ONE GLOBAL MAXIMUM CANNOT SET EVERY CELL'S TIMESTEP. A stable step is a property of the cell: a violent
# cell subdivides its own time and the quiet interior steps once. This gate holds the global budget --
# the drained maxima it read, the table-wide celerity floor, the cap it was denied against -- deleted.
# EXIT 0 clean · 1 a global budget is back · 2 could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh" 2>/dev/null || true
command -v rg >/dev/null 2>&1 || { echo "check_no_global_cfl: rg absent — a gate that cannot run FAILS." >&2; exit 2; }

SIM="$ROOT/addons/local_agents/sim"
[ -d "$SIM" ] || { echo "check_no_global_cfl: MISSING $SIM" >&2; exit 2; }

BANNED='cfl_|SUBSTEP_MAX|SUBSTEPS_DENIED|_c_static'
fail=0
# This gate names what it bans, so it may not search itself.
hits="$(rg -n --no-heading "$BANNED" "$SIM" "$ROOT/scripts" "$ROOT/docs" \
	-g '!*.import' -g '!check_no_global_cfl.sh' 2>/dev/null)"
if [ -n "$hits" ]; then
	echo "check_no_global_cfl: a global CFL budget is back." >&2
	printf '%s\n' "$hits" >&2
	fail=1
fi

# The per-cell replacement has to BE there: the level field, the sort it drives, and the suffix dispatch.
KERNEL="$SIM/material/kernels3d/flux.glsl"
LEVELS="$SIM/material/kernels3d/active_levels.glsli"
for f in "$KERNEL" "$LEVELS"; do
	[ -f "$f" ] || { echo "check_no_global_cfl: MISSING $f" >&2; exit 2; }
done
for token in la_row_level PASS_LEVEL_PEAK PASS_LEVEL_SORT TF_LEVEL; do
	rg -q "$token" "$KERNEL" "$LEVELS" || {
		echo "check_no_global_cfl: the flux kernel carries no '$token', so no cell has its own clock." >&2
		fail=1
	}
done
rg -q 'la_dt = la_level_dt' "$KERNEL" || {
	echo "check_no_global_cfl: nothing sets the per-cell timestep, so dt is global again." >&2
	fail=1
}

[ "$fail" -eq 0 ] || exit 1
echo "check_no_global_cfl: OK (no global budget; the level field, its sort and the per-cell clock are all present)"
