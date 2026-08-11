#!/usr/bin/env bash
# =====================================================================================================
# VOXEL GRID — the structural claims of the uniform Cartesian grid, checked rather than asserted.
#
# The cubed-sphere grid this replaces had to EARN reciprocity: a face seam table, family orientation
# repair, a kernel-order slot permutation, and a reciprocal-slot lookup that was wrong for all four
# lateral slots (matter destroyed on two faces of six, duplicated on two others). On an axis-aligned
# grid the opposite of d IS d ^ 1 and there is nothing to get wrong — but "nothing to get wrong" is a
# claim, so it is tested.
#
# It also checks the two properties the whole migration is FOR:
#   volume_ratio == 1      every cell is the same size, so no transfer needs a donor/receiver ratio.
#                          The old grid measured 5.34 and climbing with resolution.
#   voxel alignment        a field cell is a whole number of godot_voxel voxels and the origin sits on
#                          a cell boundary, so cell <-> voxel is integer arithmetic and the terrain and
#                          the field are ONE coordinate system instead of two.
#
# EXIT CODES. 0 pass · 1 a structural claim is false · 2 could not run.
# =====================================================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-godot}"
command -v "$GODOT" >/dev/null 2>&1 || { echo "ERROR: godot not on PATH — a gate that cannot run FAILS." >&2; exit 2; }
[ -f "$REPO_ROOT/addons/local_agents/sim/voxel/VoxelGrid.gd" ] || { echo "ERROR: VoxelGrid.gd missing." >&2; exit 2; }

PROBE="$REPO_ROOT/addons/local_agents/tests/zz_voxel_grid_gate.gd"
cat > "$PROBE" <<'GD'
extends SceneTree

func _init() -> void:
	var fail: int = 0
	var g = LAVoxelGrid.new()
	g.build_over_voxel_bounds(AABB(Vector3(-660, -660, -660), Vector3(1320, 1320, 1320)), 16.0, 1.0)
	var v: Dictionary = g.validate()
	if not bool(v["ok"]): fail += 1
	if int(v["non_reciprocal"]) != 0: fail += 1
	if absf(float(v["volume_ratio"]) - 1.0) > 1.0e-9: fail += 1
	if not g.is_voxel_aligned(1.0): fail += 1
	if g.voxels_per_cell(1.0) != 16: fail += 1
	# d ^ 1 is an involution on every slot, and never maps a slot to itself.
	for d in 6:
		if LAVoxelGrid.opposite_slot(LAVoxelGrid.opposite_slot(d)) != d: fail += 1
		if LAVoxelGrid.opposite_slot(d) == d: fail += 1
	# A neighbour step and its reverse return to the start, on an interior cell.
	var c: int = g.index(3, 4, 5)
	for d in 6:
		var m: int = g.neighbours[c * 6 + d]
		if m < 0: fail += 1
		elif g.neighbours[m * 6 + LAVoxelGrid.opposite_slot(d)] != c: fail += 1
	# A small asymmetric grid: index/coords round-trip over every cell.
	var h = LAVoxelGrid.new()
	h.build(5, 7, 3, 2.0, Vector3(-4.0, 6.0, 0.0))
	if h.cell_count != 105: fail += 1
	for i in h.cell_count:
		var p: Vector3i = h.coords(i)
		if h.index(p.x, p.y, p.z) != i: fail += 1
		if h.cell_at(h.cell_world_pos(i)) != i: fail += 1
	# Boundary faces are -1, never a wrapped neighbour.
	if h.neighbours[h.index(0, 0, 0) * 6 + LAVoxelGrid.S_NEG_X] != -1: fail += 1
	if h.neighbours[h.index(4, 6, 2) * 6 + LAVoxelGrid.S_POS_Z] != -1: fail += 1
	print('VOXEL_GRID={"cells":%d,"non_reciprocal":%d,"volume_ratio":%.6f,"voxels_per_cell":%d,"failures":%d}'
		% [int(v["cells"]), int(v["non_reciprocal"]), float(v["volume_ratio"]), g.voxels_per_cell(1.0), fail])
	quit(1 if fail > 0 else 0)
GD

out="$("$GODOT" --headless --path "$REPO_ROOT" -s "res://addons/local_agents/tests/zz_voxel_grid_gate.gd" 2>&1)"
rc=$?
rm -f "$PROBE" "$PROBE.uid"

line="$(printf '%s\n' "$out" | grep -m1 '^VOXEL_GRID=')"
if [ -z "$line" ]; then
  echo "ERROR: the probe produced no VOXEL_GRID line — refusing to report a pass." >&2
  printf '%s\n' "$out" | tail -20 >&2
  exit 2
fi
echo "$line"
if [ "$rc" -ne 0 ]; then
  echo
  echo "A structural claim of the uniform grid is false. These are the properties the cubed-sphere grid"
  echo "had to earn with a seam table and got wrong; on this grid they should hold by construction."
  exit 1
fi
echo "check_voxel_grid: OK"
