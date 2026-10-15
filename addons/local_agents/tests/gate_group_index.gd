extends SceneTree

## LAGroupIndex against a whole-group scan, in one physics frame: members moved across cells, the parent
## turned under them, members joining and leaving. Prints GROUP_INDEX={"queries":N,"failures":N}.

const GROUP: String = "gate_group_index"


class Member:
	extends Node3D
	var index: LAGroupIndex = null

	func _notification(what: int) -> void:
		if what == NOTIFICATION_LOCAL_TRANSFORM_CHANGED and index != null:
			index.moved(self)


var _done: bool = false
var _queries: int = 0
var _failures: int = 0


func _check(index: LAGroupIndex, pos: Vector3, radius: float, what: String) -> void:
	_queries += 1
	var got: Array = index.nearby(self, GROUP, pos, radius)
	var order: int = -1
	var members: Array = get_nodes_in_group(GROUP)
	for n in members:
		var inside: bool = (n as Node3D).global_position.distance_to(pos) <= radius
		if inside and not got.has(n):
			_failures += 1
			print("GROUP_INDEX_MISS %s %s" % [what, n.name])
		var at: int = got.find(n)
		if at >= 0:
			if at < order:
				_failures += 1
				print("GROUP_INDEX_ORDER %s" % what)
			order = at
	for n in got:
		if not (n as Node).is_in_group(GROUP):
			_failures += 1
			print("GROUP_INDEX_STALE %s %s" % [what, n.name])


func _member(parent: Node3D, index: LAGroupIndex, rng: RandomNumberGenerator, i: int) -> Member:
	var m: Member = Member.new()
	m.name = "m%d" % i
	m.index = index
	parent.add_child(m)
	m.position = Vector3(rng.randf_range(-400, 400), rng.randf_range(-400, 400), rng.randf_range(-400, 400))
	m.add_to_group(GROUP)
	m.set_notify_local_transform(true)
	return m


func _process(_d: float) -> bool:
	if _done:
		return true
	_done = true
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = 97
	var body: Node3D = Node3D.new()
	body.position = Vector3(10.0, 6.6e6, -20.0)
	get_root().add_child(body)
	var index: LAGroupIndex = LAGroupIndex.new()
	var ms: Array = []
	for i in 200:
		ms.append(_member(body, index, rng, i))
	for trial in 400:
		var q: Vector3 = body.to_global(Vector3(rng.randf_range(-400, 400), rng.randf_range(-400, 400), rng.randf_range(-400, 400)))
		var r: float = rng.randf_range(5.0, 150.0)
		match trial % 4:
			0:
				var m: Member = ms[rng.randi_range(0, ms.size() - 1)]
				m.position += Vector3(rng.randf_range(-200, 200), rng.randf_range(-200, 200), rng.randf_range(-200, 200))
				q = m.global_position
			1:
				body.rotate(Vector3(0.3, 1.0, 0.1).normalized(), rng.randf_range(0.001, 0.2))
			2:
				var gone: Member = ms.pop_at(rng.randi_range(0, ms.size() - 1))
				gone.remove_from_group(GROUP)
				var born: Member = _member(body, index, rng, 1000 + trial)
				index.joined(born)
				ms.append(born)
				q = born.global_position
			3:
				ms.append(_member(body, index, rng, 2000 + trial))
		_check(index, q, r, "trial%d" % trial)
	print("GROUP_INDEX=%s" % JSON.stringify({"queries": _queries, "failures": _failures}))
	quit()
	return true
