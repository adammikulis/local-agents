class_name LAEarthquake
extends Node3D


const DURATION: float = 3.0                 # brief node lifetime; the wave outlives it in the field
const SCARE_RADIUS: float = 130.0
const QUAKE_MAGNITUDE: float = 14.0         # stress released in the single seismic pulse (generous → the wave crosses a wide area)

var _terrain: Object = null
var _ecology: Object = null
var _center: Vector3 = Vector3.ZERO
var _age: float = 0.0


func setup(terrain: Object, ecology: Object) -> void:
	_terrain = terrain
	_ecology = ecology


func rupture(center: Vector3) -> void:
	_center = center
	global_position = center
	_age = 0.0
	# THE single stress-release: one seismic pulse into the shared field. broadcast_seismic forwards to
	# emit_shock, seeding a wave that propagates + attenuates on the GPU shock channel — the ground
	# disturbance, camera shake and creature panic all emerge from that wave, no per-pulse scatter here.
	if _ecology != null and _ecology.has_method("broadcast_seismic"):
		_ecology.broadcast_seismic(_center, QUAKE_MAGNITUDE)
	# One onset terror broadcast (the same stimulus every disaster reuses → emergent flee, no per-case code).
	if _ecology != null and _ecology.has_method("broadcast_scare"):
		_ecology.broadcast_scare(_center, SCARE_RADIUS, 1.0)
	LAAudioDirector.emit(get_tree(), "meteor_impact", _center)


func _process(delta: float) -> void:
	_age += delta
	if _age >= DURATION:
		queue_free()
