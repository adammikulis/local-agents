class_name LAGroupIndex
extends RefCounted

## Group members bucketed by their position in their shared parent's frame, so the body turning under
## them moves nothing. A member re-buckets when it moves (`moved`) and is added when it joins (`joined`);
## a group whose size differs from the count indexed is rebuilt. A query is exact at any moment.

const CELL_SIZE: float = 64.0

static var _shared: LAGroupIndex = null
## Queries answered and members a whole-group scan found that a query missed, under LA_GROUP_INDEX_CHECK.
static var checked: int = 0
static var missed: int = 0


static func shared() -> LAGroupIndex:
	if _shared == null:
		_shared = LAGroupIndex.new()
		if OS.get_environment("LA_GROUP_INDEX_CHECK") != "":
			LASimReport.register(func() -> Dictionary: return {"group_index_checked": checked,
				"group_index_missed": missed})
	return _shared


# group -> { Vector3i -> Array[Node3D] }
var _buckets: Dictionary = {}
# group -> { Node3D -> Vector3i }
var _cell: Dictionary = {}
# group -> { Node3D -> index in get_nodes_in_group at the last rebuild }
var _order: Dictionary = {}
# group -> the Node3D every member is a child of
var _parent: Dictionary = {}
# group -> members indexed and still counted
var _count: Dictionary = {}
# group -> the order a member joining now takes
var _next: Dictionary = {}


static func _cell_of(p: Vector3) -> Vector3i:
	return Vector3i(int(floor(p.x / CELL_SIZE)), int(floor(p.y / CELL_SIZE)), int(floor(p.z / CELL_SIZE)))


func _add(g: String, n: Node3D, key: Vector3i) -> void:
	var cells: Dictionary = _buckets[g]
	if not cells.has(key):
		cells[key] = []
	(cells[key] as Array).append(n)
	(_cell[g] as Dictionary)[n] = key


func _rebuild(tree: SceneTree, g: String) -> void:
	_buckets[g] = {}
	_cell[g] = {}
	var order: Dictionary = {}
	var members: Array = tree.get_nodes_in_group(g)
	var parent: Node = null
	for i in members.size():
		var n = members[i]
		if not is_instance_valid(n) or not (n is Node3D):
			continue
		var n3: Node3D = n as Node3D
		if parent == null:
			parent = n3.get_parent()
		elif n3.get_parent() != parent:
			push_error("LAGroupIndex: '%s' has members under two parents, so one frame cannot place them." % g)
		order[n3] = i
		_add(g, n3, _cell_of(n3.position))
	_order[g] = order
	_parent[g] = parent
	_count[g] = members.size()
	_next[g] = members.size()


## A member's local transform changed: move it to its new bucket in every group it is indexed in.
func moved(n: Node3D) -> void:
	var key: Vector3i = _cell_of(n.position)
	for g in _cell:
		var cells: Dictionary = _cell[g]
		if not cells.has(n):
			continue
		var old: Vector3i = cells[n]
		if old == key:
			continue
		var arr: Variant = (_buckets[g] as Dictionary).get(old)
		if arr != null:
			(arr as Array).erase(n)
		_add(g, n, key)


## A node entered groups: add it to every indexed group it is now in, after the members already there.
func joined(n: Node3D) -> void:
	for g in _cell:
		if not n.is_in_group(g) or (_cell[g] as Dictionary).has(n) or n.get_parent() != _parent[g]:
			continue
		_add(g, n, _cell_of(n.position))
		(_order[g] as Dictionary)[n] = int(_next[g])
		_next[g] = int(_next[g]) + 1
		_count[g] = int(_count[g]) + 1


## Members of `g` that can lie within `radius` of the world point `pos`, in get_nodes_in_group order so
## first-found and tie rules match a whole-group scan. The caller does the exact distance test.
func nearby(tree: SceneTree, g: String, pos: Vector3, radius: float) -> Array:
	if int(_count.get(g, -1)) != tree.get_node_count_in_group(g):
		_rebuild(tree, g)
	var parent: Node3D = _parent[g] as Node3D
	if parent == null:
		return []
	var p: Vector3 = parent.to_local(pos)
	var lo: Vector3i = _cell_of(p - Vector3.ONE * radius)
	var hi: Vector3i = _cell_of(p + Vector3.ONE * radius)
	var cells: Dictionary = _buckets[g]
	var order: Dictionary = _order[g]
	var out: Array = []
	for cx in range(lo.x, hi.x + 1):
		for cy in range(lo.y, hi.y + 1):
			for cz in range(lo.z, hi.z + 1):
				var arr: Variant = cells.get(Vector3i(cx, cy, cz))
				if arr == null:
					continue
				for n in arr as Array:
					if is_instance_valid(n) and (n as Node).is_in_group(g):
						out.append(n)
	out.sort_custom(func(a: Node, b: Node) -> bool: return int(order[a]) < int(order[b]))
	if OS.get_environment("LA_GROUP_INDEX_CHECK") != "":
		_check(tree, g, pos, radius, out)
	return out


# Every member a whole-group scan puts inside the range must be in `got`.
func _check(tree: SceneTree, g: String, pos: Vector3, radius: float, got: Array) -> void:
	checked += 1
	for n in tree.get_nodes_in_group(g):
		if not (n is Node3D) or got.has(n):
			continue
		if (n as Node3D).global_position.distance_to(pos) <= radius:
			missed += 1
			push_error("LAGroupIndex: '%s' query at %s r=%.2f missed %s." % [g, pos, radius, n])
