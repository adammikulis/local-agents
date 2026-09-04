class_name LAStartLocalHour
extends RefCounted

## Turn the body to the hour the world starts at: an initial condition of the spin, applied once.


## Rotate `sim`'s body so the slice site reads `hour` of its own local day. Negative keeps the seed phase.
static func apply(sim, hour: float) -> void:
	if hour < 0.0 or sim == null:
		return
	var body: Node3D = sim.body()
	var star: Node3D = sim.star()
	var field: Node = sim.material_field()
	if body == null or star == null or field == null:
		return
	var slice = field._slice if "_slice" in field else null
	if slice == null or not body.has_method("spin_axis"):
		return
	var axis: Vector3 = body.spin_axis()
	var sun: Vector3 = (star.global_position - body.center()).normalized()
	var turn: float = _phase(body.global_transform.basis * Vector3(slice.offset).normalized(), sun, axis, hour)
	if is_finite(turn) and not is_zero_approx(turn):
		body.rotate(axis.normalized(), turn)


## The spin angle about `axis` that brings the site's meridian to the sun's, plus the hour's own share of
## a turn. A site on the axis has no meridian and no hour.
static func _phase(here: Vector3, sun: Vector3, axis: Vector3, hour: float) -> float:
	var n: Vector3 = axis.normalized()
	var a: Vector3 = here - n * here.dot(n)
	var b: Vector3 = sun - n * sun.dot(n)
	if a.length() < 1.0e-6 or b.length() < 1.0e-6:
		return 0.0
	a = a.normalized()
	b = b.normalized()
	return atan2(a.cross(b).dot(n), a.dot(b)) + (hour - 12.0) * TAU / 24.0
