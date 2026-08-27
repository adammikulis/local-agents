class_name LAGravity
extends Object


const GROUP: String = "gravity_body"


static func _bodies(tree: SceneTree) -> Array:
	return tree.get_nodes_in_group(GROUP) if tree != null else []


## A body pulls only once it can say how much matter it is. A body whose mass is still unmeasured reports
## a negative, and a negative mass in a sum of pulls is a repulsion nothing in the world does.
static func _is_body(b: Object) -> bool:
	if b == null or not b.has_method("mass") or not b.has_method("center"):
		return false
	var m: float = float(b.mass())
	return is_finite(m) and m > 0.0


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


## NEWTON'S CONSTANT. It is a measured property of the universe, so it is read, never solved for.
##
static func gravitational_constant(_tree: SceneTree = null) -> float:
	return LAPhysical.GRAVITATIONAL_CONSTANT


## Standard gravitational parameter GM of one body (the only place a "mu" exists — derived, never typed).
static func mu(tree: SceneTree, body: Object) -> float:
	var g: float = gravitational_constant(tree)
	if g <= 0.0 or not _is_body(body):
		return 0.0
	return g * float(body.mass())


# Newtonian pull of a body of parameter `mu` and radius `r_body` centred at `from_center`, evaluated at
# `at`. INSIDE the body only the enclosed mass pulls, so the acceleration falls off linearly to zero at the
# centre (Newton's shell theorem) instead of diverging. That is the real law, not a softened one.
static func _pull(mu_val: float, r_body: float, from_center: Vector3, at: Vector3) -> Vector3:
	var d: Vector3 = from_center - at
	var len_d: float = d.length()
	if len_d < 1.0e-6:
		return Vector3.ZERO
	var dir: Vector3 = d / len_d
	if r_body > 0.0 and len_d < r_body:
		return dir * (mu_val * len_d / (r_body * r_body * r_body))
	return dir * (mu_val / (len_d * len_d))


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
		var r_b: float = _radius_of(b)
		if b != exclude:
			a += _pull(mu_b, r_b, c, pos)
		if b != frame:
			a -= _pull(mu_b, r_b, c, frame_c)
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
		# G is common to every term, so mu = mass compares the same order as the real pull.
		var ai: float = _pull(float(b.mass()), _radius_of(b), b.center() as Vector3, pos).length()
		if ai > best_a:
			best_a = ai
			best = b
	return best


## A body's own radius, or -1.0 when it does not publish one — outside every body the radius never enters
## the law, so a body that cannot answer is only a body nothing may be inside of.
static func _radius_of(b: Object) -> float:
	if b == null or not b.has_method("radius"):
		return -1.0
	var r: float = float(b.radius())
	return r if is_finite(r) and r > 0.0 else -1.0


## Circular-orbit speed about the dominant body at `pos` (v = sqrt(|a| * r)). 0 if no body / no G yet.
static func circular_speed(tree: SceneTree, pos: Vector3) -> float:
	var g: float = gravitational_constant(tree)
	if g <= 0.0:
		return 0.0
	var b: Object = dominant_body(tree, pos)
	if b == null:
		return 0.0
	var r: float = ((b.center() as Vector3) - pos).length()
	if r <= 0.0:
		return 0.0
	var a: float = _pull(g * float(b.mass()), _radius_of(b), b.center() as Vector3, pos).length()
	return sqrt(a * r)
