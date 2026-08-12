@tool
extends RefCounted


const STAR_MASS: float = 1.0e7
const STAR_RADIUS: float = 250.0
const PLANET_MASS: float = 1.0e6
const PLANET_RADIUS: float = 500.0
const TOLERANCE: float = 0.25          # |a| is summed over both bodies, so the distant star shifts it slightly


class StubBody:
	extends Node3D

	var _m: float = 0.0
	var _r: float = 0.0
	var _ref: bool = false

	func configure(m: float, r: float, is_ref: bool) -> void:
		_m = m
		_r = r
		_ref = is_ref

	func mass() -> float:
		return _m

	func radius() -> float:
		return _r

	func center() -> Vector3:
		return global_position

	func is_gravity_reference() -> bool:
		return _ref


func run_test(tree: SceneTree) -> bool:
	var star: StubBody = StubBody.new()
	star.configure(STAR_MASS, STAR_RADIUS, false)
	star.global_position = Vector3(12000.0, 0.0, 0.0)
	tree.root.add_child(star)
	star.add_to_group(LAGravity.GROUP)

	# THE WINDOW: the heavier body is registered and something asks for gravity before the planet exists.
	# This is the query that used to poison the cache permanently.
	var g_star_only: float = LAGravity.gravitational_constant(tree)

	var planet: StubBody = StubBody.new()
	planet.configure(PLANET_MASS, PLANET_RADIUS, true)
	planet.global_position = Vector3.ZERO
	tree.root.add_child(planet)
	planet.add_to_group(LAGravity.GROUP)

	var expected_g: float = LAGravity.SURFACE_G * PLANET_RADIUS * PLANET_RADIUS / PLANET_MASS
	var g_after: float = LAGravity.gravitational_constant(tree)
	var surface_a: float = LAGravity.acceleration_at(tree, Vector3(PLANET_RADIUS, 0.0, 0.0)).length()
	var ref_after: Object = LAGravity.reference_body(tree)

	var ok: bool = true
	ok = _assert(ref_after == planet,
		"reference_body must prefer the body that declares is_gravity_reference(), not the most massive one") and ok
	ok = _assert(absf(g_after - expected_g) < 0.0001,
		"G must re-derive against the planet once it registers; expected %f, got %f (star-only was %f)"
			% [expected_g, g_after, g_star_only]) and ok
	ok = _assert(absf(surface_a - LAGravity.SURFACE_G) < TOLERANCE,
		"surface gravity must be ~%f at the planet's radius, got %f — G is calibrated against the wrong body"
			% [LAGravity.SURFACE_G, surface_a]) and ok

	star.queue_free()
	planet.queue_free()
	if ok:
		print("Gravity calibration test passed (G re-derives when the reference body changes; surface |a| = %.4f)"
			% surface_a)
	return ok


func _assert(condition: bool, message: String) -> bool:
	if not condition:
		push_error(message)
	return condition
