#!/usr/bin/env bash
# =====================================================================================================
# VOXEL GRID — the structural claims of the GRADED Cartesian grid, checked rather than asserted.
#   volume_ratio == 8         a 2:1 neighbour's volume ratio is EXACTLY eight, never a near miss
#   ratio_violations == 0     no pair differs by anything else
#   area_violations == 0      the four fine faces across a coarse face tile it exactly
#   non_reciprocal == 0       every face names the face that points back, through `partners`
# Plus: every transfer across such a face goes through `cellvol.glsli`'s vol_ratio(donor, receiver).
# A channel value is a FILL FRACTION of the cell holding it, so a 2:1 crossing without the ratio
# creates or destroys seven eighths of what crossed.
# EXIT CODES. 0 pass · 1 a structural claim is false · 2 could not run.
# =====================================================================================================
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_godot.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_capture.sh"
la_examined "$(basename "$0")" || exit $?

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-godot}"
command -v "$GODOT" >/dev/null 2>&1 || { echo "ERROR: godot not on PATH — a gate that cannot run FAILS." >&2; exit 2; }
[ -f "$REPO_ROOT/addons/local_agents/sim/voxel/VoxelGrid.gd" ] || { echo "ERROR: VoxelGrid.gd missing." >&2; exit 2; }

PROBE_REL="addons/local_agents/tests/gate_voxel_grid.gd"
[ -f "$REPO_ROOT/$PROBE_REL" ] || { echo "ERROR: MISSING $PROBE_REL." >&2; exit 2; }

if la_cap_dir >/dev/null; then
  out="$(la_headless voxel_grid)" || exit 2
else
  out="$(la_godot --headless --path "$REPO_ROOT" -s "res://$PROBE_REL" 2>&1)"
fi

line="$(printf '%s\n' "$out" | grep -m1 '^VOXEL_GRID=')"
if [ -z "$line" ]; then
  echo "ERROR: the probe produced no VOXEL_GRID line — refusing to report a pass." >&2
  printf '%s\n' "$out" | tail -20 >&2
  exit 2
fi
echo "$line"
# The marker carries the verdict; a batched runner has no exit code of its own.
fails="$(printf '%s' "$line" | grep -oE '"failures":[0-9]+' | grep -oE '[0-9]+$')"
[ -n "$fails" ] || { echo "ERROR: the probe published no failure count." >&2; exit 2; }
ratio="$(printf '%s' "$line" | grep -oE '"volume_ratio":[0-9.]+' | grep -oE '[0-9.]+$')"
[ -n "$ratio" ] || { echo "ERROR: the probe published no volume ratio." >&2; exit 2; }
if [ "$fails" -ne 0 ]; then
  echo
  echo "A structural claim of the graded grid is false: a 2:1 pair whose volumes are not eight to one,"
  echo "a coarse face its four fine faces do not tile, or a face with no partner pointing back."
  exit 1
fi
# The refined arm's own reading, so a probe that quietly stopped refining cannot pass this gate.
case "$ratio" in
  8|8.0|8.0*) ;;
  *) echo "check_voxel_grid: the refined grid reports volume_ratio $ratio, not 8." >&2; exit 1 ;;
esac

# A 2:1 SEAM CREATES NO MATTER. One shared area, stated by the FINER of the pair, and each side turns
# that face's per-area flux into its own per-volume change by dividing by its own volume. The two
# absolute amounts are then equal whatever the refinement, with no ratio to get the wrong way round.
K="$REPO_ROOT/addons/local_agents/sim/material/kernels3d"
grep -q 'float vol_ratio(uint donor, uint receiver)' "$K/cellvol.glsli" || {
  echo "check_voxel_grid: cellvol.glsli no longer declares vol_ratio(donor, receiver)." >&2; exit 1; }
grep -qE 'float s = nb >= 0 \? min\(e, cell_edge\[uint\(nb\)\]\) : e;' "$K/cellvol.glsli" || {
  echo "check_voxel_grid: la_face_area no longer takes the FINER cell's edge, so the two sides of a" >&2
  echo "  2:1 seam disagree about how much area they share." >&2; exit 1; }
grep -qE 'return la_face_area\(c, nb\) / max\(cell_volume\(c\), 1e-30\);' "$K/cellvol.glsli" || {
  echo "check_voxel_grid: la_face_div no longer divides the shared area by the cell's OWN volume." >&2
  exit 1; }
for expr in 'float div_f = la_face_div\(c, inb\);' '\* la_dt \* div_f'; do
  grep -qE "$expr" "$K/flux.glsl" || {
    echo "check_voxel_grid: flux.glsl does not turn a face flux into the cell's own per-volume" >&2
    echo "  change ($expr absent), so matter crossing a 2:1 seam is created or destroyed." >&2
    exit 1; }
done
# And nothing may index per-face scratch by a fixed six-slot stride any more.
if grep -nE '(face_u|fp_star|x_amt|x_h|x_q|send|nbr|ghost)\[[^]]*N_SLOTS' "$K"/*.glsl "$K"/*.glsli; then
  echo "check_voxel_grid: a per-face buffer is still indexed by a fixed six-slot stride." >&2
  exit 1
fi
echo "check_voxel_grid: OK"
