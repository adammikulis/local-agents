class_name LAThrownRock
extends Node3D

## A rock in flight. Steers toward a moving target with a mild ballistic arc,
## strikes (kills) the target on proximity, spawns a brief impact puff, and
## cleans itself up. Robust against null/invalid targets and terrain.

const HIT_RADIUS: float = 1.3
const MAX_LIFETIME: float = 4.0
const ARC_HEIGHT: float = 1.5

var _terrain: Object = null
var _target: Node3D = null
var _speed: float = 22.0
var _flying: bool = false
var _elapsed: float = 0.0
var _start_pos: Vector3 = Vector3.ZERO
var _initial_distance: float = 0.0

func setup(terrain) -> void:
	_terrain = terrain

	var material: StandardMaterial3D = StandardMaterial3D.new()
	material.albedo_color = Color(0.4, 0.38, 0.35)
	material.roughness = 1.0
	material.metallic = 0.0

	var mesh: BoxMesh = BoxMesh.new()
	mesh.size = Vector3(0.35, 0.35, 0.35)
	mesh.material = material

	var mesh_instance: MeshInstance3D = MeshInstance3D.new()
	mesh_instance.name = "ThrownRockMesh"
	mesh_instance.mesh = mesh
	mesh_instance.rotation = Vector3(
		randf_range(-0.4, 0.4),
		randf_range(0.0, TAU),
		randf_range(-0.4, 0.4)
	)
	add_child(mesh_instance)

func throw_at(from: Vector3, target: Node3D, speed: float = 22.0) -> void:
	global_position = from
	_start_pos = from
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

	global_position = pos

	# Safety: expired lifetime.
	if _elapsed > MAX_LIFETIME:
		queue_free()
		return

	# Safety: dropped below terrain surface at current x,z.
	if _terrain != null and _terrain.has_method("surface_height"):
		var surf = _terrain.surface_height(global_position.x, global_position.z)
		if (typeof(surf) == TYPE_FLOAT or typeof(surf) == TYPE_INT) and not is_nan(float(surf)):
			if global_position.y < float(surf):
				queue_free()
				return

func _strike() -> void:
	_flying = false
	if is_instance_valid(_target):
		if _target.has_method("on_struck"):
			_target.on_struck()
		else:
			_target.queue_free()
	_spawn_impact_puff()
	queue_free()

func _spawn_impact_puff() -> void:
	var parent: Node = get_parent()
	if parent == null:
		return

	var puff: GPUParticles3D = GPUParticles3D.new()
	puff.name = "ImpactPuff"
	puff.one_shot = true
	puff.emitting = true
	puff.amount = 12
	puff.lifetime = 0.5
	puff.explosiveness = 1.0

	var particle_mesh: SphereMesh = SphereMesh.new()
	particle_mesh.radius = 0.05
	particle_mesh.height = 0.1
	puff.draw_pass_1 = particle_mesh

	var process_material: ParticleProcessMaterial = ParticleProcessMaterial.new()
	process_material.direction = Vector3(0, 1, 0)
	process_material.spread = 45.0
	process_material.initial_velocity_min = 1.0
	process_material.initial_velocity_max = 3.0
	process_material.gravity = Vector3(0, -9.8, 0)
	process_material.color = Color(0.4, 0.38, 0.35)
	puff.process_material = process_material

	parent.add_child(puff)
	puff.global_position = global_position

	# Auto-free the puff shortly after it finishes.
	var timer: Timer = Timer.new()
	timer.one_shot = true
	timer.wait_time = 1.0
	puff.add_child(timer)
	timer.timeout.connect(puff.queue_free)
	timer.start()
