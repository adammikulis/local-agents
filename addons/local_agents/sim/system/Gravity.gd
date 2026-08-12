class_name LAGravity
extends Object


const GROUP: String = "gravity_body"
const SURFACE_G: float = 55.0        # target surface gravity (units/s^2) on the reference body
const SOFTENING: float = 4.0         # min separation (units) so accel can't blow up as r -> 0 inside a body

static var _g_const: float = -1.0
static var _g_ref_id: int = 0


static func _bodies(tree: SceneTree) -> Array:
	return tree.get_nodes_in_group(GROUP) if tree != null else []


static func _is_body(b: Object) -> bool:
	return b != null and b.has_method("mass") and b.has_method("center")


static func reference_body(tree: SceneTree) -> Object:
	var flagged: Object = null
	var best: Object = null
	var best_m: float = -1.0
	for b in _bodies(tree):
		if not _is_body(b):
			continue
		if flagged == null and b.has_method("is_gravity_reference") and bool(b.is_gravity_reference()):
			flagged = b
		var m: float = float(b.mass())
		if m > best_m:
			best_m = m
			best = b
	return flagged if flagged != null else best


static func gravitational_constant(tree: SceneTree) -> float:
	var p: Object = reference_body(tree)
	if p != null and p.has_method("radius"):
		var live_id: int = p.get_instance_id()
		if _g_const > 0.0 and _g_ref_id == live_id:
			return _g_const
		var r: float = float(p.radius())
		var m: float = float(p.mass())
		if r > 1.0 and m > 0.0:
			_g_const = SURFACE_G * r * r / m
			_g_ref_id = live_id
			return _g_const
	return -1.0   # no usable body yet → acceleration_at returns ZERO, and we retry next call


## Standard gravitational parameter GM of one body (the only place a "mu" exists — derived, never typed).
static func mu(tree: SceneTree, body: Object) -> float:
	var g: float = gravitational_constant(tree)
	if g <= 0.0 or not _is_body(body):
		return 0.0
	return g * float(body.mass())


# Newtonian pull of a mass with parameter `mu` centred at `from_center`, evaluated at `at`. Softened so a
# point inside a body cannot blow up.
static func _pull(mu_val: float, from_center: Vector3, at: Vector3) -> Vector3:
	var d: Vector3 = from_center - at
	var len_d: float = d.length()
	if len_d < 1.0e-6:
		return Vector3.ZERO
	var r: float = maxf(len_d, SOFTENING)
	return (d / len_d) * (mu_val / (r * r))


static func acceleration_at(tree: SceneTree, pos: Vector3, exclude: Object = null) -> Vector3:
	var g: float = gravitational_constant(tree)
	if g <= 0.0:
		return Vector3.ZERO
	var frame: Object = reference_body(tree)
	if frame == null:
		return Vector3.ZERO
	var frame_c: Vector3 = frame.center() as Vector3
	var a: Vector3 = Vector3.ZERO
	for b in _bodies(tree):
		if not _is_body(b):
			continue
		var mu_b: float = g * float(b.mass())
		var c: Vector3 = b.center() as Vector3
		if b != exclude:
			a += _pull(mu_b, c, pos)
		if b != frame:
			a -= _pull(mu_b, c, frame_c)
	return a


## The body whose DIRECT pull dominates at `pos` (for impact tests, radial "up", and circular-speed).
## Null if none. Deliberately the direct pull, not the frame-corrected one: "which body am I near" is a
## question about geometry, and near the planet the answer must stay the planet.
static func dominant_body(tree: SceneTree, pos: Vector3) -> Object:
	var best: Object = null
	var best_a: float = -1.0
	for b in _bodies(tree):
		if not _is_body(b):
			continue
		var d: Vector3 = (b.center() as Vector3) - pos
		var r: float = maxf(d.length(), SOFTENING)
		var ai: float = float(b.mass()) / (r * r)   # G is common → compare mass/r^2 directly
		if ai > best_a:
			best_a = ai
			best = b
	return best


## Circular-orbit speed about the dominant body at `pos` (v = sqrt(|a| * r)). 0 if no body / no G yet.
static func circular_speed(tree: SceneTree, pos: Vector3) -> float:
	var g: float = gravitational_constant(tree)
	if g <= 0.0:
		return 0.0
	var b: Object = dominant_body(tree, pos)
	if b == null:
		return 0.0
	var d: Vector3 = (b.center() as Vector3) - pos
	var r: float = maxf(d.length(), SOFTENING)
	var a: float = g * float(b.mass()) / (r * r)
	return sqrt(a * r)
