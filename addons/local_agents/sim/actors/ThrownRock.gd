class_name LAThrownRock
extends Node3D


const HIT_RADIUS: float = 1.3
const MAX_LIFETIME: float = 4.0
const ARC_HEIGHT: float = 1.5
## The stone's edge, m: what it weighs and what the view draws.
const STONE_SIDE: float = 0.35

## The stone reached its target at `at`.
signal struck(at: Vector3)

var velocity: Vector3 = Vector3.ZERO            # m/s, over the last physics tick

var _terrain: Object = null
var _water: Object = null
var _target: Node3D = null
var _speed: float = 22.0
var _flying: bool = false
var _elapsed: float = 0.0
var _initial_distance: float = 0.0

func setup(terrain, water = null) -> void:
	_terrain = terrain
	_water = water

func throw_at(from: Vector3, target: Node3D, speed: float = 22.0) -> void:
	global_position = from
	_target = target
	_speed = maxf(speed, 0.1)
	_elapsed = 0.0
	_flying = true
	if is_instance_valid(_target):
		_initial_distance = maxf(from.distance_to(_target.global_position), 0.001)
	else:
		_initial_distance = 0.001

func _physics_process(delta: float) -> void:
	if not _flying:
		return

	if not is_instance_valid(_target):
		queue_free()
		return

	_elapsed += delta

	var target_pos: Vector3 = _target.global_position
	var pos: Vector3 = global_position

	# Steer toward the target's current position.
	var to_target: Vector3 = target_pos - pos
	var distance: float = to_target.length()

	if distance <= HIT_RADIUS:
		_strike()
		return

	var direction: Vector3 = to_target / maxf(distance, 0.0001)
	pos += direction * _speed * delta

	# Mild parabolic arc: peak height when halfway to the target, zero at ends.
	var progress: float = clampf(1.0 - (distance / _initial_distance), 0.0, 1.0)
	var arc_offset: float = sin(progress * PI) * ARC_HEIGHT
	pos.y += arc_offset * delta * _speed * 0.15

	velocity = (pos - global_position) / delta
	global_position = pos

	# Safety: expired lifetime.
	if _elapsed > MAX_LIFETIME:
		queue_free()
		return

	# Safety: dropped below the terrain surface (radial altitude < 0 = underground).
	if _terrain != null and _terrain.has_method("altitude_at"):
		var alt: float = _terrain.altitude_at(global_position)
		if not is_nan(alt) and alt < 0.0:
			_maybe_splash(global_position)
			queue_free()
			return

func _strike() -> void:
	_flying = false
	if is_instance_valid(_target) and _target.has_method("on_struck"):
		_target.on_struck()
	_maybe_splash(global_position)
	struck.emit(global_position)
	queue_free()


# Splash accent if the rock came down in water.
func _maybe_splash(at: Vector3) -> void:
	if _water != null and _water.has_method("splash"):
		var kg: float = STONE_SIDE * STONE_SIDE * STONE_SIDE * LASubstances.solid_density("silicate")
		_water.splash(at, 0.5 * kg * _speed * _speed)
