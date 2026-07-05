class_name LAFlood
extends Node3D

## A flash flood. It only PUMPS a surge of water into the MaterialField over an area for a few
## seconds; the water then flows and pools by its own CA, and drowning (non-flyers in deep water),
## firebreaks, and animals fleeing to high ground all EMERGE. Splash accents + scare. Self-frees when
## the surge ends. (Explicit types only — no ':=' inferred typing.)

const DURATION: float = 3.0
const SURGE_RATE: float = 2.2             # water depth/sec added across the pooled footprint
const RADIUS_SCALE: float = 1.5          # surge footprint = spawn brush radius x this (a flood spreads a bit wider than the brush)
const MIN_RADIUS: float = 4.0            # a pinpoint brush still floods a small basin
const SCARE_MULT: float = 2.4            # animals flee a wider ring than the water itself covers

var _ecology: Object = null
var _field: Object = null
var _center: Vector3 = Vector3.ZERO
var _radius: float = MIN_RADIUS
var _age: float = 0.0
var _splash_cd: float = 0.0


func setup(_terrain: Object, ecology: Object) -> void:
	_ecology = ecology
	if _ecology != null and _ecology.has_method("material_field"):
		_field = _ecology.material_field()


# `brush_radius` ties the flood footprint to the player's spawn brush (VoxelWorld._brush_radius) so a
# flood only ever covers where they aimed — no more world-wide surge. The water is POOLED into the low
# ground here and flows out downhill via the field CA, so it never appears on higher ground / uphill.
func surge(center: Vector3, brush_radius: float = MIN_RADIUS) -> void:
	_center = center
	_radius = maxf(brush_radius * RADIUS_SCALE, MIN_RADIUS)
	global_position = center
	_age = 0.0
	LocalAgentsAudioDirector.emit(get_tree(), "steam", _center)
	if _ecology != null and _ecology.has_method("broadcast_scare"):
		_ecology.broadcast_scare(_center, _radius * SCARE_MULT, 0.9)


func _process(delta: float) -> void:
	_age += delta
	if _age < DURATION and _field != null and _field.has_method("add_water_pooled"):
		# Pour into the basin only (cells at/below the centre ground height); the CA does the spreading.
		_field.add_water_pooled(_center, SURGE_RATE * delta, _radius)
		_splash_cd -= delta
		if _splash_cd <= 0.0 and _field.has_method("splash"):
			_splash_cd = 0.25
			var ang: float = randf() * TAU
			var rr: float = randf() * _radius
			_field.splash(_center + Vector3(cos(ang) * rr, 0.5, sin(ang) * rr), 2.0)
	if _age >= DURATION + 1.0:
		queue_free()
