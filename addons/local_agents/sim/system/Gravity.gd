class_name LAGravity
extends Object

## The scene's side of `LABallistics`: one walk of the gravity group per physics frame turns the body
## nodes into the point-mass rows the extension integrates against. No law lives here.

const GROUP: String = "gravity_body"

static var _nodes: Array = []
static var _published_frame: int = -1


## A body pulls only once it can say how much matter it is. A body whose mass is still unmeasured reports
## a negative, and a negative mass in a sum of pulls is a repulsion nothing in the world does.
static func _is_body(b: Object) -> bool:
	if b == null or not b.has_method("mass") or not b.has_method("center"):
		return false
	var m: float = float(b.mass())
	return is_finite(m) and m > 0.0


static func _radius_of(b: Object) -> float:
	if b == null or not b.has_method("radius"):
		return -1.0
	var r: float = float(b.radius())
	return r if is_finite(r) and r > 0.0 else -1.0


## The frame the scene's coordinates are measured from: the flagged body, else the most massive.
static func _frame_of(bodies: Array) -> Object:
	var flagged: Object = null
	var best: Object = null
	var best_m: float = -1.0
	for b in bodies:
		if flagged == null and b.has_method("is_gravity_reference") and bool(b.is_gravity_reference()):
			flagged = b
		var m: float = float(b.mass())
		if m > best_m:
			best_m = m
			best = b
	return flagged if flagged != null else best


## Hand the extension the system as it stands. Call it after moving a body; every accessor below
## republishes on its own once per physics frame.
static func publish(tree: SceneTree) -> void:
	_nodes = []
	var rows: Array = []
	if tree != null:
		for b in tree.get_nodes_in_group(GROUP):
			if _is_body(b):
				_nodes.append(b)
	var frame: Object = _frame_of(_nodes)
	for b in _nodes:
		rows.append({
			"center": b.center() as Vector3,
			"mass_kg": float(b.mass()),
			"radius_m": _radius_of(b),
			"frame": b == frame,
		})
	LABallistics.set_system(rows)
	_published_frame = Engine.get_physics_frames()


static func _ensure(tree: SceneTree) -> void:
	if _published_frame != Engine.get_physics_frames():
		publish(tree)


static func acceleration_at(tree: SceneTree, pos: Vector3, exclude: Object = null) -> Vector3:
	_ensure(tree)
	return LABallistics.acceleration_at(pos, _nodes.find(exclude) if exclude != null else -1)


## The body whose DIRECT pull dominates at `pos` (for impact tests, radial "up", and circular-speed).
static func dominant_body(tree: SceneTree, pos: Vector3) -> Object:
	_ensure(tree)
	var i: int = LABallistics.dominant(pos)
	return _nodes[i] if i >= 0 and i < _nodes.size() else null


static func circular_speed(tree: SceneTree, pos: Vector3) -> float:
	_ensure(tree)
	return LABallistics.circular_speed(pos)


## True when the orbit about the body nearest `pos` has non-negative specific energy: it left the system.
static func is_unbound(tree: SceneTree, pos: Vector3, vel: Vector3) -> bool:
	_ensure(tree)
	var i: int = LABallistics.dominant(pos)
	if i < 0:
		return false
	var r: float = pos.distance_to(LABallistics.body_center(i))
	if r <= 0.0:
		return false
	var v: float = vel.length()
	return 0.5 * v * v - LABallistics.body_mu(i) / r >= 0.0


## GM of the whole system, m^3/s^2: what a conic about it is drawn against.
static func system_mu(tree: SceneTree) -> float:
	_ensure(tree)
	var total: float = 0.0
	for i in range(LABallistics.system_size()):
		total += LABallistics.body_mu(i)
	return total


## The field's own state, handed over whenever it re-solves: the grid, the drained gravity mirror, the
## solid mask, the channel mirrors a medium's mass density is summed from, and the body frame the grid
## is laid in — a free body flies in the world's frame and the box rides the body's.
static func publish_field(field) -> void:
	if field == null or field._grid == null or field._gravity == null:
		LABallistics.clear_field()
		return
	field.sync_body_frame()
	LABallistics.set_field(field._grid, field._gravity.mirror(), field._solid,
		LAFieldCellMass3D.mirrors(field), field._body_basis, field.centre())
