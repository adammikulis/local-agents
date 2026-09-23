class_name LASpatialIndex
extends RefCounted


const CELL_SIZE: float = 64.0
## Metres a live creature can travel inside one physics frame, and so the reach a frame-old bucket is
## widened by: a creature's tick moves it by at most its speed over a strided dt, well inside this.
const MOVE_MARGIN_M: float = 8.0

static var _shared: LASpatialIndex = null


## The index a creature's tick asks `nearby` of, one for every caller.
static func shared() -> LASpatialIndex:
	if _shared == null:
		_shared = LASpatialIndex.new()
	return _shared


# group name (String) -> { Vector3i cell -> Array[Node3D] }
var _buckets: Dictionary = {}
# group name (String) -> physics frame it was last (re)built on
var _group_frame: Dictionary = {}
# group name (String) -> { Node3D -> Vector3i last cell }, so a touch only moves nodes whose cell changed
var _node_cell: Dictionary = {}
# group name (String) -> { Node3D -> its index in get_nodes_in_group at the last rebuild }
var _order: Dictionary = {}
# group name (String) -> member count at the last rebuild
var _count: Dictionary = {}
# group name (String) -> Vector2i(lowest, highest) y cell a member stood in at the last rebuild
var _y_span: Dictionary = {}


## 3D cell containing `pos` (x/y/z), so the spherical shell partitions instead of collapsing onto XZ.
func _cell_of(pos: Vector3) -> Vector3i:
	return Vector3i(int(floor(pos.x / CELL_SIZE)), int(floor(pos.y / CELL_SIZE)), int(floor(pos.z / CELL_SIZE)))


func _bucket_add(cells: Dictionary, key: Vector3i, n: Node3D) -> void:
	var arr: Variant = cells.get(key)
	if arr == null:
		arr = []
		cells[key] = arr
	(arr as Array).append(n)


## `n` is Variant, not Node3D: a stale-cleanup call passes a node freed since the last touch, and a
## Node3D-typed parameter would reject it at the call boundary before the erase-by-identity below runs.
func _bucket_remove(cells: Dictionary, key: Vector3i, n: Variant) -> void:
	var arr: Variant = cells.get(key)
	if arr == null:
		return
	(arr as Array).erase(n)
	if (arr as Array).is_empty():
		cells.erase(key)


## Re-registers only the nodes of `group_names` whose cell actually changed since the last touch this
## frame — a node that has not crossed a cell boundary costs nothing here.
func rebuild_if_stale(tree: SceneTree, frame: int, group_names: Array) -> void:
	if tree == null:
		return
	for gname in group_names:
		var g: String = String(gname)
		if int(_group_frame.get(g, -1)) == frame:
			continue
		if not _buckets.has(g):
			_buckets[g] = {}
		if not _node_cell.has(g):
			_node_cell[g] = {}
		var cells: Dictionary = _buckets[g]
		var node_cell: Dictionary = _node_cell[g]
		var seen: Dictionary = {}
		var order: Dictionary = {}
		var members: Array = tree.get_nodes_in_group(g)
		for i in members.size():
			var n = members[i]
			if not is_instance_valid(n) or not (n is Node3D):
				continue
			var n3: Node3D = n as Node3D
			seen[n3] = true
			order[n3] = i
			var new_key: Vector3i = _cell_of(n3.global_position)
			if node_cell.has(n3):
				if (node_cell[n3] as Vector3i) == new_key:
					continue
				_bucket_remove(cells, node_cell[n3] as Vector3i, n3)
			_bucket_add(cells, new_key, n3)
			node_cell[n3] = new_key
		var stale: Array = []
		for n3 in node_cell:
			if not seen.has(n3):
				stale.append(n3)
		for n3 in stale:
			_bucket_remove(cells, node_cell[n3] as Vector3i, n3)
			node_cell.erase(n3)
		_group_frame[g] = frame
		_order[g] = order
		_count[g] = members.size()
		var span: Vector2i = Vector2i(0, -1)
		for n3 in node_cell:
			var cy: int = (node_cell[n3] as Vector3i).y
			span = Vector2i(cy, cy) if span.y < span.x else Vector2i(mini(span.x, cy), maxi(span.y, cy))
		_y_span[g] = span


## A superset of `group_name` within the box [pos ± radius]; `column` spans every y cell the group
## holds, for a horizontal range. Empty if the group was never indexed.
func query(group_name: String, pos: Vector3, radius: float, column: bool = false) -> Array:
	var cells: Dictionary = _buckets.get(group_name, {})
	if cells.is_empty():
		return []
	var min_cx: int = int(floor((pos.x - radius) / CELL_SIZE))
	var max_cx: int = int(floor((pos.x + radius) / CELL_SIZE))
	var min_cy: int = int(floor((pos.y - radius) / CELL_SIZE))
	var max_cy: int = int(floor((pos.y + radius) / CELL_SIZE))
	if column:
		var span: Vector2i = _y_span.get(group_name, Vector2i(0, -1))
		min_cy = span.x
		max_cy = span.y
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


## Members of `g` that can lie within `radius` of `pos`, in get_nodes_in_group order so first-found and
## tie rules match a whole-group scan. Rebuilt per physics frame or on a size change; the caller does the
## exact distance test.
func nearby(tree: SceneTree, g: String, pos: Vector3, radius: float, column: bool = false) -> Array:
	if int(_count.get(g, -1)) != tree.get_node_count_in_group(g):
		_group_frame.erase(g)
	rebuild_if_stale(tree, Engine.get_physics_frames(), [g])
	var order: Dictionary = _order.get(g, {})
	var out: Array = []
	for n in query(g, pos, radius + MOVE_MARGIN_M, column):
		if is_instance_valid(n) and (n as Node).is_in_group(g):
			out.append(n)
	out.sort_custom(func(a: Node, b: Node) -> bool: return int(order[a]) < int(order[b]))
	return out
