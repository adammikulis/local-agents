class_name LAGravity
extends Object

## Outer-Wilds-style N-BODY gravity (a HARD PRINCIPLE of this project — see the nbody-gravity memory).
## Every body in the `gravity_body` group is a MASS at a position (LAPlanetBody / LAStar expose center()+mass()).
## Any free body — a meteor, ejecta, later a ship or the player — is a TEST PARTICLE whose acceleration is the
## SUMMED inverse-square pull of ALL of them. One gravitational constant G is calibrated once so surface gravity
## on the primary body feels right; from that single rule, orbits, elliptical capture, flybys and slingshots
## EMERGE — there is no hardcoded single-centre or world-axis gravity anywhere. (Explicit types; no ':='.)

const GROUP: String = "gravity_body"
const SURFACE_G: float = 55.0        # target surface gravity (units/s^2) on the primary body — matches old feel
const SOFTENING: float = 4.0         # min separation (units) so accel can't blow up as r -> 0 inside a body

static var _g_const: float = -1.0    # gravitational constant, calibrated lazily from the primary body


static func _bodies(tree: SceneTree) -> Array:
	return tree.get_nodes_in_group(GROUP) if tree != null else []


## The most massive body — the calibration reference and default dominant attractor. Null if none registered.
static func primary_body(tree: SceneTree) -> Object:
	var best: Object = null
	var best_m: float = -1.0
	for b in _bodies(tree):
		if b.has_method("mass") and b.has_method("center"):
			var m: float = float(b.mass())
			if m > best_m:
				best_m = m
				best = b
	return best


## G calibrated so |a| == SURFACE_G at the primary body's surface radius; cached after the first solve.
static func gravitational_constant(tree: SceneTree) -> float:
	if _g_const > 0.0:
		return _g_const
	var p: Object = primary_body(tree)
	if p != null and p.has_method("radius"):
		var r: float = float(p.radius())
		var m: float = float(p.mass())
		if r > 1.0 and m > 0.0:
			_g_const = SURFACE_G * r * r / m
			return _g_const
	return _g_const   # stays -1 (no bodies yet) → acceleration_at returns ZERO until one exists


## Summed gravitational acceleration (units/s^2) at a world point from EVERY registered body.
static func acceleration_at(tree: SceneTree, pos: Vector3) -> Vector3:
	var g: float = gravitational_constant(tree)
	if g <= 0.0:
		return Vector3.ZERO
	var a: Vector3 = Vector3.ZERO
	for b in _bodies(tree):
		if not (b.has_method("mass") and b.has_method("center")):
			continue
		var d: Vector3 = (b.center() as Vector3) - pos
		var r: float = maxf(d.length(), SOFTENING)
		a += d.normalized() * (g * float(b.mass()) / (r * r))
	return a


## The body whose pull dominates at `pos` (for impact tests, radial "up", and circular-speed). Null if none.
static func dominant_body(tree: SceneTree, pos: Vector3) -> Object:
	var g: float = gravitational_constant(tree)
	var best: Object = null
	var best_a: float = -1.0
	for b in _bodies(tree):
		if not (b.has_method("mass") and b.has_method("center")):
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
