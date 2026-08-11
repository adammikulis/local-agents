class_name LAFlood
extends Node3D

## A flash flood as an EMERGENT CLOUDBURST, not a spawn of water from nothing. It conjures NO water and (since
## 2026-08-03) no heat either: like a Thunderstorm it seeds the physical ingredients of a violent downpour into
## the MaterialField and lets the unified water cycle rain it out. Each step it PUMPS humid air (add_vapor) up
## over the footprint — a transfer that debits the footprint's own liquid and soil water — and lets the
## substrate's buoyancy and lapse rate carry it. Unlike a
## drifting storm cell it STAYS PUT over the target and pumps far harder for a few seconds, so the rain runs
## off, pools in the low ground, and the current sweeps + drowns whatever is caught (all emergent, since the water
## is atmospheric moisture becoming surface water, conserved, never created). Splash accents + a scare on
## arrival (animals flee to high ground, and the ones that can't are swept). Self-frees. (Explicit types only, no ':=' inferred typing.)

const DURATION: float = 4.5              # seconds of torrential seeding
const FADE_TIME: float = 1.5             # eases the seeding out at the end so it tapers, not cuts
const RADIUS_SCALE: float = 1.5          # cloudburst footprint = requested radius x this (rain spreads wider than the aim)
const MIN_RADIUS: float = 6.0
const SCARE_MULT: float = 2.6            # animals flee a wider ring than the rain footprint

# Seeding rates — cranked well above a Thunderstorm's so a few seconds makes a genuine deluge that pools.
const VAPOR_PER_SEC: float = 26.0        # total humid air pumped up per second (split over the injection points)
const VAPOR_INJECT_R: float = 16.0
# A CLOUDBURST CARRIES NO ENERGY SOURCE. The four constants that used to sit here — SEED_HEAT_PER_SEC = 8.0
# and SEED_HEAT_R = 18.0 (surface warming), COOL_PER_SEC = 34.0 and COOL_INJECT_R = 34.0 (heat destroyed
# aloft) — are deleted along with the two injections that used them. The class doc above was already half
# right and half wrong about itself: the WATER really is conserved (add_vapor is a transfer that debits the
# footprint's own liquid and soil water), but the HEAT was manufactured at the bottom of the column and
# annihilated at the top, 8 °C/s in and 34 °C/s out, for the flood's whole life. Nothing paid for either.
const CLOUD_ALOFT: float = 58.0          # height above the ground the moisture is lofted toward (cloud base)

var _terrain: Object = null
var _ecology: Object = null
var _field: Object = null
var _center: Vector3 = Vector3.ZERO
var _up: Vector3 = Vector3.UP
var _radius: float = MIN_RADIUS
var _age: float = 0.0
var _splash_cd: float = 0.0


func setup(terrain: Object, ecology: Object) -> void:
	_terrain = terrain
	_ecology = ecology
	if _ecology != null and _ecology.has_method("material_field"):
		_field = _ecology.material_field()


# `brush_radius` is the caller's rain footprint, in metres. The field's flow CA pools + routes it downhill.
func surge(center: Vector3, brush_radius: float = MIN_RADIUS) -> void:
	_center = center
	_radius = maxf(brush_radius * RADIUS_SCALE, MIN_RADIUS)
	global_position = center
	_age = 0.0
	# Local radial up (so the aloft cooling is injected straight overhead on the sphere, not along world +Y).
	if _terrain != null and _terrain.has_method("up_at"):
		var u: Vector3 = _terrain.up_at(_center)
		if u.length() > 0.0001:
			_up = u.normalized()
	LAAudioDirector.emit(get_tree(), "steam", _center)
	if _ecology != null and _ecology.has_method("broadcast_scare"):
		_ecology.broadcast_scare(_center, _radius * SCARE_MULT, 1.1)


func _physics_process(delta: float) -> void:
	_age += delta
	if _age >= DURATION + FADE_TIME + 1.0 or _field == null:
		if _age >= DURATION + FADE_TIME + 1.0:
			queue_free()
		return
	var intensity: float = _seed_scale()
	if intensity > 0.0:
		_pump_cloudburst(intensity, delta)
	# Splash accents where the rain is hammering the pooling water (visual only).
	_splash_cd -= delta
	if _splash_cd <= 0.0 and _field.has_method("splash"):
		_splash_cd = 0.2
		var ang: float = randf() * TAU
		var rr: float = randf() * _radius
		_field.splash(_center + _tangent(ang) * rr, 2.0)


# Full-strength through DURATION, then eases out over FADE_TIME so the storm rains itself out instead of cutting.
func _seed_scale() -> float:
	if _age <= DURATION:
		return 1.0
	return clampf((DURATION + FADE_TIME - _age) / FADE_TIME, 0.0, 1.0)


# Pump the cloudburst ingredients across the footprint: humid air + surface heat at several ground points, and
# hard cooling in the air column overhead — the field then condenses cloud → heavy rain here on its own.
func _pump_cloudburst(intensity: float, delta: float) -> void:
	var offsets: Array = [0.0, 1.0, 2.0, 3.0, 4.0, 5.0]     # a FULL ring of angles (0..300°) + centre — spreads the cell evenly (was 0..150°, one-sided)
	var pts: int = offsets.size() + 1
	var per_vapor: float = VAPOR_PER_SEC * intensity * delta / float(pts)
	# Centre.
	_seed_point(_center, per_vapor)
	# Ring.
	for a in offsets:
		var ang: float = float(a) * TAU / float(offsets.size())
		_seed_point(_center + _tangent(ang) * (_radius * 0.6), per_vapor)


func _seed_point(gpos: Vector3, vapor: float) -> void:
	# Drop each injection to the local ground so vapor rises from the surface (not from mid-air). The moisture
	# is the ONLY thing seeded now: `add_vapor` lifts water that is really there (the footprint's liquid and its
	# water table) and reports what it could not find, so a cloudburst over dry ground is a weak one. The
	# surface-warming call that used to sit beside it created heat from nothing and is gone.
	var p: Vector3 = gpos
	if _terrain != null and _terrain.has_method("ground_point"):
		var g: Vector3 = _terrain.ground_point(gpos)
		if not is_nan(g.x):
			p = g
	if _field.has_method("add_vapor"):
		_field.add_vapor(p + _up * 3.0, vapor, VAPOR_INJECT_R)


# A unit vector in the local tangent plane at `_center` for angle `ang` (so the footprint hugs the sphere).
func _tangent(ang: float) -> Vector3:
	var t1: Vector3 = _up.cross(Vector3.RIGHT)
	if t1.length_squared() < 1.0e-4:
		t1 = _up.cross(Vector3.FORWARD)
	t1 = t1.normalized()
	var t2: Vector3 = _up.cross(t1).normalized()
	return (t1 * cos(ang) + t2 * sin(ang)).normalized()
