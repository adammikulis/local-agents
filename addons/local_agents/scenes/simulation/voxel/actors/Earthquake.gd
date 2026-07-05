class_name LAEarthquake
extends Node3D

## An earthquake. It only SHAKES the ground over an area and opens a few fissures; the destruction
## emerges: steep terrain slumps downhill under gravity (the same disturb rule landslides use), trees
## and rocks topple, and wildlife panics. Its ground disturbances emit seismic pulses, so the CAMERA
## SHAKE EMERGES from the ecology's seismic field — the quake never touches the camera. Runs a couple
## of seconds of pulses, then frees. (Explicit types only — no ':=' inferred typing.)

const DURATION: float = 3.0
const PULSE_INTERVAL: float = 0.35
const AREA_RADIUS: float = 75.0
const SCARE_RADIUS: float = 130.0
const DISTURBS_PER_PULSE: int = 4

var _terrain: Object = null
var _ecology: Object = null
var _center: Vector3 = Vector3.ZERO
var _age: float = 0.0
var _pulse_cd: float = 0.0


func setup(terrain: Object, ecology: Object) -> void:
	_terrain = terrain
	_ecology = ecology


func rupture(center: Vector3) -> void:
	_center = center
	global_position = center
	_age = 0.0
	_pulse_cd = 0.0
	# An initial seismic jolt at the epicentre; the camera shakes emergently through the seismic field.
	if _ecology != null and _ecology.has_method("broadcast_seismic"):
		_ecology.broadcast_seismic(_center, 4.0)
	LocalAgentsAudioDirector.emit(get_tree(), "meteor_impact", _center)


func _process(delta: float) -> void:
	_age += delta
	_pulse_cd -= delta
	if _pulse_cd <= 0.0 and _age < DURATION:
		_pulse_cd = PULSE_INTERVAL
		_pulse()
	if _age >= DURATION + 1.0:
		queue_free()


func _pulse() -> void:
	# Scatter ground disturbances (steep spots slump) + open fissures across the area.
	for i in range(DISTURBS_PER_PULSE):
		var ang: float = randf() * TAU
		var rr: float = sqrt(randf()) * AREA_RADIUS
		var px: float = _center.x + cos(ang) * rr
		var pz: float = _center.z + sin(ang) * rr
		var p: Vector3 = Vector3(px, _center.y, pz)
		if _ecology != null and _ecology.has_method("disturb_ground"):
			_ecology.disturb_ground(p, 18.0, 1.6)
		if _terrain != null and _terrain.has_method("carve_sphere") and _terrain.has_method("surface_height"):
			var h = _terrain.surface_height(px, pz)
			if typeof(h) == TYPE_FLOAT and not is_nan(float(h)):
				_terrain.carve_sphere(Vector3(px, float(h), pz), randf_range(1.5, 3.2))
	if _ecology != null and _ecology.has_method("broadcast_scare"):
		_ecology.broadcast_scare(_center, SCARE_RADIUS, 1.0)
	if randf() < 0.5:
		LocalAgentsAudioDirector.emit(get_tree(), "crumble", _center)
