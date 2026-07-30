class_name LAGravity
extends Object

## Outer-Wilds-style N-BODY gravity (a HARD PRINCIPLE of this project, see the nbody-gravity memory).
## Every body in the `gravity_body` group is a MASS at a position (LAPlanetBody / LAStar / LAMoon expose
## center()+mass()+radius()). Any free body (a meteor, an ejecta parcel, later a ship or the player) is a
## TEST PARTICLE whose acceleration is the SUMMED pull of ALL of them. ONE gravitational constant G is
## calibrated once, from the REFERENCE body, so surface gravity where you stand feels right; from that
## single rule orbits, capture, flybys and slingshots EMERGE, and there is no hardcoded single-centre or
## world-axis gravity anywhere. (Explicit types; no ':='.)
##
## ONE SYSTEM, ONE G. The star is a member of this group like everything else, and the planet's own
## heliocentric orbit is integrated by THIS function too (LASystemOrbits._integrate_orbit), so a mass
## expressed here is the same mass that sets the year. There is no second gravity constant in second
## units. (Before 2026-07-30 there was: `SUN_MU = 1e6` in LASystemOrbits drove the orbit while the star
## was not a gravity body at all, and the visible sun sat at a decorative `SUN_SCENE_DISTANCE = 1200`
## unrelated to the orbital distance it was supposedly at.)
##
## THE FRAME — read this before adding a force. World space is the PLANET-CENTRED, NON-ROTATING frame.
## The planet sits at the world origin and NEVER TRANSLATES (terrain, field, ocean and actors are its
## children; moving it would re-stream the whole voxel LOD every frame and burn fp32 precision under a
## camera that renders from the surface). It is the STAR that sweeps around the scene. So "the orbit" is
## a RELATIVE state — the planet-to-star separation — not an absolute position, and this frame is in FREE
## FALL, which means it is NOT INERTIAL.
##
## A test particle must therefore NOT be handed the star's full pull: the planet is falling toward the
## star at the same rate, so the shared part cancels. The correct planetocentric equation subtracts each
## non-frame body's pull ON THE FRAME ORIGIN (the "indirect" term), leaving the TIDAL differential:
##
##     a(p) = Σ_i  G·m_i·(c_i − p)/|c_i − p|³        (direct: what every body pulls on the particle)
##          − Σ_i≠frame  G·m_i·(c_i − c_frame)/|c_i − c_frame|³   (indirect: what it pulls on the origin)
##
## That one subtraction is what makes a star affordable at all. Handed the raw direct sum, a star massive
## enough to swing the planet around drags EVERYTHING sunward everywhere at a large constant rate — the
## world visibly leaks toward the sun and every meteor rails into the clamp. With the indirect term the
## uniform part is gone, what is left grows with distance from the planet, the Hill sphere is real, bound
## things stay bound, and only what climbs out of the Hill sphere gets taken by the star. It also gives
## the moon's relative motion its (M_planet + M_moon) reduced mass for free.

const GROUP: String = "gravity_body"
const SURFACE_G: float = 55.0        # target surface gravity (units/s^2) on the reference body — matches old feel
const SOFTENING: float = 4.0         # min separation (units) so accel can't blow up as r -> 0 inside a body

# G is cached, but keyed on WHICH body calibrated it. A bare static cache is a load-order trap: the first
# caller to ask before any body registered used to latch the failure, and a scene reload would keep a G
# calibrated against the previous world's radius. Storing the reference's instance id makes the cache
# self-invalidating and makes a failed calibration retry instead of stick.
static var _g_const: float = -1.0
static var _g_ref_id: int = 0


static func _bodies(tree: SceneTree) -> Array:
	return tree.get_nodes_in_group(GROUP) if tree != null else []


static func _is_body(b: Object) -> bool:
	return b != null and b.has_method("mass") and b.has_method("center")


## The body G is calibrated against AND the origin of the world frame (see the frame note above): the
## body that declares `is_gravity_reference()` — the planet you stand on — else the most massive one.
## NOT simply "max mass": the star outweighs the planet by design, and calibrating SURFACE_G against a
## star's surface would rescale gravity for the whole world.
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


## G calibrated so |a| == SURFACE_G at the reference body's surface radius. Cached per reference body.
##
## THE CACHE IS KEYED ON WHICH BODY IS THE REFERENCE RIGHT NOW, and re-derives the moment that changes.
## Checking merely that the remembered id is still ALIVE is a different question and a silent trap:
## `reference_body` falls back to max mass until some body declares `is_gravity_reference()`, and the star
## outweighs the planet 10:1 by design. So one gravity query inside the window where the star has registered
## and the planet has not would calibrate G against a 250-radius, 1e7-mass star and keep answering with it
## forever — surface gravity 3.10 against the intended 55, for the life of the process, nothing logged.
## The shipped boot order does not open that window (VoxelWorld registers the star, then the planet, inside
## one `_ready()` with no query between), but "correct only because of the order two unrelated lines happen
## to run in" is not an invariant, and silent degradation on the gravity path is exactly what this repo
## fails fast on. Re-deriving costs one more pass over the handful of gravity bodies, which `acceleration_at`
## already walks anyway.
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


## Summed gravitational acceleration (units/s^2) at a world point, in the PLANET-CENTRED frame this world
## renders in: every body's direct pull, MINUS every non-frame body's pull on the frame origin (see the
## frame note in the class doc — that subtraction is the whole reason a star is affordable here).
## `exclude` skips one body's DIRECT term so a body can be integrated with this same call without pulling
## on itself; its indirect term is kept, which is exactly what turns the moon's equation into (M_p + M_m).
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
