class_name LAStar
extends Node3D


const DEFAULT_MASS: float = 1.0e7        # 10x the planet's 1e6 — the star has to dominate to be a star
const DEFAULT_RADIUS: float = 250.0

var _light: DirectionalLight3D = null       # for a single close body, a directional light reads as "the sun"
var _mass: float = DEFAULT_MASS
var _radius: float = DEFAULT_RADIUS
var _base_energy: float = 1.4
var _ref_distance: float = 600.0            # distance at which insolation == _base_energy (for 1/dist² scaling)


func setup(opts: Dictionary = {}) -> void:
	_mass = float(opts.get("mass", DEFAULT_MASS))
	_radius = float(opts.get("radius", DEFAULT_RADIUS))
	_base_energy = float(opts.get("energy", 1.4))
	_ref_distance = float(opts.get("ref_distance", 600.0))
	position = opts.get("position", Vector3(900.0, 300.0, 600.0))

	_light = DirectionalLight3D.new()
	_light.name = "StarLight"
	_light.light_energy = _base_energy
	_light.shadow_enabled = true
	add_child(_light)
	aim_at(Vector3.ZERO)

	# Join the N-body group only once the position above is real. Registering in _ready() would put a mass
	# this large at the world origin — on top of the planet — for the window between add_child and setup.
	add_to_group(LAGravity.GROUP)


func mass() -> float:
	return _mass

func radius() -> float:
	return _radius

## World-space centre — the N-body contract shared with LAPlanetBody and LAMoon.
func center() -> Vector3:
	return global_position

func light() -> DirectionalLight3D:
	return _light

## Unit direction from a body's centre TOWARD the star — the body's local "sun_dir" for the terminator.
func sun_dir_for(body_center: Vector3) -> Vector3:
	var d: Vector3 = global_position - body_center
	return d.normalized() if d.length() > 0.001 else Vector3.UP

## Insolation (light energy) reaching a body at `body_center`: inverse-square from the reference distance.
func insolation_at(body_center: Vector3) -> float:
	var dist: float = maxf(1.0, global_position.distance_to(body_center))
	return _base_energy * (_ref_distance * _ref_distance) / (dist * dist)

func aim_at(target: Vector3) -> void:
	if _light == null:
		return
	var to: Vector3 = target - global_position
	if to.length() > 0.001:
		_light.look_at_from_position(global_position, target, Vector3.UP)
