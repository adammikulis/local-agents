class_name LAFlood
extends Node3D

## A flash flood. It only PUMPS a surge of water into the MaterialField over an area for a few
## seconds; the water then flows and pools by its own CA, and drowning (non-flyers in deep water),
## firebreaks, and animals fleeing to high ground all EMERGE. Splash accents + scare. Self-frees when
## the surge ends. (Explicit types only — no ':=' inferred typing.)

const Mat: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/Materials.gd")

const DURATION: float = 3.0
const SURGE_RATE: float = 2.2             # water depth/sec added across the disc
const RADIUS: float = 42.0
const SCARE_RADIUS: float = 70.0

var _ecology: Object = null
var _field: Object = null
var _center: Vector3 = Vector3.ZERO
var _age: float = 0.0
var _splash_cd: float = 0.0


func setup(_terrain: Object, ecology: Object) -> void:
	_ecology = ecology
	if _ecology != null and _ecology.has_method("material_field"):
		_field = _ecology.material_field()


func surge(center: Vector3) -> void:
	_center = center
	global_position = center
	_age = 0.0
	LocalAgentsAudioDirector.emit(get_tree(), "steam", _center)
	if _ecology != null and _ecology.has_method("broadcast_scare"):
		_ecology.broadcast_scare(_center, SCARE_RADIUS, 0.9)


func _process(delta: float) -> void:
	_age += delta
	if _age < DURATION and _field != null and _field.has_method("add_material"):
		_field.add_material(_center, Mat.WATER, SURGE_RATE * delta, RADIUS)
		_splash_cd -= delta
		if _splash_cd <= 0.0 and _field.has_method("splash"):
			_splash_cd = 0.25
			var ang: float = randf() * TAU
			var rr: float = randf() * RADIUS
			_field.splash(_center + Vector3(cos(ang) * rr, 0.5, sin(ang) * rr), 2.0)
	if _age >= DURATION + 1.0:
		queue_free()
