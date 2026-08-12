class_name LASpatialIndex
extends RefCounted


const CELL_SIZE: float = 64.0

# group name (String) -> { Vector3i cell -> Array[Node3D] }
var _buckets: Dictionary = {}
# group name (String) -> physics frame it was last (re)built on
var _group_frame: Dictionary = {}


## 3D cell containing `pos` (x/y/z), so the spherical shell partitions instead of collapsing onto XZ.
func _cell_of(pos: Vector3) -> Vector3i:
	return Vector3i(int(floor(pos.x / CELL_SIZE)), int(floor(pos.y / CELL_SIZE)), int(floor(pos.z / CELL_SIZE)))


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
			var key: Vector3i = _cell_of(n3.global_position)
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
	var min_cy: int = int(floor((pos.y - radius) / CELL_SIZE))
	var max_cy: int = int(floor((pos.y + radius) / CELL_SIZE))
	var min_cz: int = int(floor((pos.z - radius) / CELL_SIZE))
	var max_cz: int = int(floor((pos.z + radius) / CELL_SIZE))
	var out: Array = []
	for cx in range(min_cx, max_cx + 1):
		for cy in range(min_cy, max_cy + 1):
			for cz in range(min_cz, max_cz + 1):
				var arr: Variant = cells.get(Vector3i(cx, cy, cz))
				if arr != null:
					out.append_array(arr as Array)
	return out
