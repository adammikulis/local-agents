class_name LASpatialIndex
extends RefCounted

## Frame-stamped spatial hash over scene-group members. Replaces the per-creature O(n) group scans
## in LACreatureSenses with an O(1)-ish bucketed lookup: with 277 creatures each doing several full
## `get_nodes_in_group()` distance sweeps per physics frame the sensing was O(n²); binning candidates
## into coarse cells and visiting only the cells overlapping a query's radius collapses that to a small
## constant per query.
##
## Rebuilt at most ONCE per physics frame PER GROUP (lazily — the first sense call of a frame that needs
## a group rebuilds it; later calls that frame reuse it). All creatures share ONE index instance
## (LACreatureSenses holds it), so the whole population pays for one rebuild per group per frame.
##
## Binning is XZ-only (2D): creatures live on/near the surface, and 3D distance >= XZ distance, so a
## candidate whose true 3D distance is within `radius` is guaranteed to fall in the visited XZ cells —
## the cell set is a strict SUPERSET of the in-range set. Positions are cached at rebuild time (start of
## frame); a creature that moves within the frame is still found because the query visits neighbour cells
## and the CALLER re-checks the exact current distance (and validity/vision/species/size filters). This
## is a pure speedup — same nearest node within range as the old linear scan.
## (Explicit types only — project rule: no ':=' inferred typing.)

# Coarse cell edge in world units. Chosen >= the largest sense query radius in play: the widest query is
# nearest_visible_carrion / nearest_visible_in_state at effective_range*1.5 ≈ 20 (max sense_radius) *
# 1.4 (night) * 1.6 (binocular) * 1.5 ≈ 67. `query()` derives exact cell bounds from the radius, so a
# typical ~45u query spans a 3×3 block and a rare >64 radius just visits one extra ring — never a miss.
const CELL_SIZE: float = 64.0

# group name (String) -> { Vector2i cell -> Array[Node3D] }
var _buckets: Dictionary = {}
# group name (String) -> physics frame it was last (re)built on
var _group_frame: Dictionary = {}


## XZ cell containing `pos`.
func _cell_of(pos: Vector3) -> Vector2i:
	return Vector2i(int(floor(pos.x / CELL_SIZE)), int(floor(pos.z / CELL_SIZE)))


## Ensure every group in `group_names` is indexed for physics frame `frame`. A group already built this
## frame is skipped, so calling this from several sense methods in the same frame rebuilds each group at
## most once. Only groups actually requested are indexed (no wasted work on groups no one queries).
func rebuild_if_stale(tree: SceneTree, frame: int, group_names: Array) -> void:
	if tree == null:
		return
	for gname in group_names:
		var g: String = String(gname)
		if int(_group_frame.get(g, -1)) == frame:
			continue
		var cells: Dictionary = {}
		for n in tree.get_nodes_in_group(g):
			if not is_instance_valid(n) or not (n is Node3D):
				continue
			var n3: Node3D = n as Node3D
			var key: Vector2i = _cell_of(n3.global_position)
			var arr: Variant = cells.get(key)
			if arr == null:
				arr = []
				cells[key] = arr
			(arr as Array).append(n3)
		_buckets[g] = cells
		_group_frame[g] = frame


## Candidate nodes of `group_name` in the cells overlapping the box [pos ± radius] (XZ). A SUPERSET of the
## true in-range set — the caller still does the exact distance check and its own filters. Empty if the
## group was never indexed this frame.
func query(group_name: String, pos: Vector3, radius: float) -> Array:
	var cells: Dictionary = _buckets.get(group_name, {})
	if cells.is_empty():
		return []
	var min_cx: int = int(floor((pos.x - radius) / CELL_SIZE))
	var max_cx: int = int(floor((pos.x + radius) / CELL_SIZE))
	var min_cz: int = int(floor((pos.z - radius) / CELL_SIZE))
	var max_cz: int = int(floor((pos.z + radius) / CELL_SIZE))
	var out: Array = []
	for cx in range(min_cx, max_cx + 1):
		for cz in range(min_cz, max_cz + 1):
			var arr: Variant = cells.get(Vector2i(cx, cz))
			if arr != null:
				out.append_array(arr as Array)
	return out
