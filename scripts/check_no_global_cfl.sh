#!/usr/bin/env bash
# NO STEP IS CHOSEN, AND NO CELL IS DENIED ONE. Every cell states the seconds its own explicit closures
# afford; the field step is the shortest of those and the box's own free-fall bound. This gate holds the
# chosen budget -- a substep maximum, a denial counter, a table-wide celerity floor -- deleted, and holds
# the per-cell derivation and its reduction present.
# EXIT 0 clean · 1 a chosen budget is back, or the derivation is gone · 2 could not run.
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
	echo "check_no_global_cfl: a chosen CFL budget is back." >&2
	printf '%s\n' "$hits" >&2
	fail=1
fi

# The per-cell derivation has to BE there: the cell's own seconds, the reduction that takes the
# shortest, and the publication the clock reads.
KERNEL="$SIM/material/kernels3d/flux.glsl"
ACTIVE="$SIM/material/kernels3d/active_cells.glsli"
FLUXPASS="$SIM/material/sphere_passes/FluxPass.gd"
STEP="$SIM/material/MaterialFieldSphereStep3D.gd"
for f in "$KERNEL" "$ACTIVE" "$FLUXPASS" "$STEP"; do
	[ -f "$f" ] || { echo "check_no_global_cfl: MISSING $f" >&2; exit 2; }
done
rg -q 'float la_row_dt\(uint c\)' "$KERNEL" || {
	echo "check_no_global_cfl: the flux kernel states no per-cell step, so no cell has its own clock." >&2
	fail=1
}
rg -q 'atomicMin\(step_dt\[params.act_group\]' "$ACTIVE" || {
	echo "check_no_global_cfl: nothing reduces the cells' asks, so the step is chosen rather than taken." >&2
	fail=1
}
rg -q 'LAMaterialFieldSphereStep3D.publish_step_seconds\(dt\)' "$FLUXPASS" || {
	echo "check_no_global_cfl: FluxPass never publishes the derived step, so the clock counts something else." >&2
	fail=1
}
# THE TEMPORAL LEVELS ARE GONE: the acoustic signal is implicit, so nothing subdivides a step.
lv="$(rg -n --no-heading 'tlevel|la_level_dt|TemporalLevels|PASS_LEVEL_|transport_levels' "$SIM" \
	-g '!*.import' 2>/dev/null)"
if [ -n "$lv" ]; then
	echo "check_no_global_cfl: the temporal levels are back beside the implicit acoustic solve." >&2
	printf '%s\n' "$lv" >&2
	fail=1
fi

[ "$fail" -eq 0 ] || exit 1
echo "check_no_global_cfl: OK (no chosen budget; the per-cell step, its reduction and its publication are present)"
