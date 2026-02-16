extends Node
class_name FpsLauncherController

const DEFAULT_PROJECTILE_SCENE = preload("res://addons/local_agents/scenes/simulation/actors/FpsLauncherProjectile.tscn")
const PhysicsServerContactBridgeScript = preload("res://addons/local_agents/simulation/controller/PhysicsServerContactBridge.gd")
const FpsLauncherProfileResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/FpsLauncherProfileResource.gd")

@export var projectile_scene: PackedScene = DEFAULT_PROJECTILE_SCENE
@export_range(1.0, 300.0, 0.5) var launch_speed: float = 60.0
@export_range(0.05, 20.0, 0.01) var launch_mass: float = 0.2
@export_range(0.1, 20.0, 0.1) var projectile_ttl_seconds: float = 4.0
@export_range(0.02, 2.0, 0.01) var projectile_radius: float = 0.07
@export_range(0.1, 5.0, 0.1) var spawn_distance: float = 0.8
@export_range(0.01, 2.0, 0.01) var cooldown_seconds: float = 0.15
@export_range(1, 256, 1) var max_active_projectiles: int = 24
@export_range(1.0, 30.0, 0.5) var launch_speed_step: float = 5.0
@export_range(0.01, 4.0, 0.01) var launch_mass_step: float = 0.05
@export_range(0.05, 1.0, 0.01) var projectile_ttl_step: float = 0.1
@export_range(0.0, 180.0, 1.0) var launch_energy_scale: float = 1.0
@export_range(0.05, 10.0, 0.05) var launch_energy_scale_step: float = 0.2

const _LAUNCH_SPEED_MIN := 1.0
const _LAUNCH_SPEED_MAX := 300.0
const _LAUNCH_MASS_MIN := 0.05
const _LAUNCH_MASS_MAX := 20.0
const _TTL_MIN := 0.1
const _TTL_MAX := 20.0
const _RADIUS_MIN := 0.02
const _RADIUS_MAX := 2.0
const _ENERGY_SCALE_MIN := 0.1
const _ENERGY_SCALE_MAX := 180.0

var _camera: Camera3D = null
var _spawn_parent: Node3D = null
var _cooldown_remaining: float = 0.0
var _active_projectiles: Array[RigidBody3D] = []
var _pending_contact_rows: Array[Dictionary] = []
var _sampled_contact_cursor: int = 0
const _MAX_PENDING_CONTACT_ROWS := 96

func configure(active_camera: Camera3D, spawn_parent: Node3D, profile_resource: Resource = null) -> void:
	_camera = active_camera
	_spawn_parent = spawn_parent
	_apply_profile_resource(profile_resource)

func _apply_profile_resource(profile_resource: Resource) -> void:
	if profile_resource == null:
		return
	var values: Dictionary = {}
	if profile_resource is FpsLauncherProfileResourceScript:
		values = (profile_resource as FpsLauncherProfileResourceScript).to_dict()
	elif profile_resource.has_method("to_dict"):
		var values_variant = profile_resource.call("to_dict")
		if values_variant is Dictionary:
			values = (values_variant as Dictionary).duplicate(true)
	if values.is_empty():
		var launch_speed_value: Variant = profile_resource.get("launch_speed")
		if launch_speed_value != null:
			values["launch_speed"] = launch_speed_value
		var launch_mass_value: Variant = profile_resource.get("launch_mass")
		if launch_mass_value != null:
			values["launch_mass"] = launch_mass_value
		var projectile_radius_value: Variant = profile_resource.get("projectile_radius")
		if projectile_radius_value != null:
			values["projectile_radius"] = projectile_radius_value
		var projectile_ttl_value: Variant = profile_resource.get("projectile_ttl_seconds")
		if projectile_ttl_value != null:
			values["projectile_ttl_seconds"] = projectile_ttl_value
		var launch_energy_scale_value: Variant = profile_resource.get("launch_energy_scale")
		if launch_energy_scale_value != null:
			values["launch_energy_scale"] = launch_energy_scale_value
	launch_speed = clampf(float(values.get("launch_speed", launch_speed)), _LAUNCH_SPEED_MIN, _LAUNCH_SPEED_MAX)
	launch_mass = clampf(float(values.get("launch_mass", launch_mass)), _LAUNCH_MASS_MIN, _LAUNCH_MASS_MAX)
	projectile_radius = clampf(float(values.get("projectile_radius", projectile_radius)), _RADIUS_MIN, _RADIUS_MAX)
	projectile_ttl_seconds = clampf(float(values.get("projectile_ttl_seconds", projectile_ttl_seconds)), _TTL_MIN, _TTL_MAX)
	launch_energy_scale = clampf(float(values.get("launch_energy_scale", launch_energy_scale)), _ENERGY_SCALE_MIN, _ENERGY_SCALE_MAX)

func handle_hotkey(event: InputEvent) -> bool:
	if not (event is InputEventKey):
		return false
	var key_event := event as InputEventKey
	if not key_event.pressed or key_event.echo:
		return false
	var step_scale := 1.0
	if key_event.shift_pressed:
		step_scale = 4.0
	if key_event.ctrl_pressed:
		step_scale = 0.25
	var adjusted_speed_step = launch_speed_step * step_scale
	var adjusted_mass_step = launch_mass_step * step_scale
	var adjusted_ttl_step = projectile_ttl_step * step_scale
	var adjusted_energy_step = launch_energy_scale_step * step_scale
	match key_event.keycode:
		KEY_BRACKETLEFT:
			launch_speed = clampf(launch_speed - adjusted_speed_step, _LAUNCH_SPEED_MIN, _LAUNCH_SPEED_MAX)
			_print_profile("launcher speed")
			return true
		KEY_BRACKETRIGHT:
			launch_speed = clampf(launch_speed + adjusted_speed_step, _LAUNCH_SPEED_MIN, _LAUNCH_SPEED_MAX)
			_print_profile("launcher speed")
			return true
		KEY_MINUS:
			launch_mass = clampf(launch_mass - adjusted_mass_step, _LAUNCH_MASS_MIN, _LAUNCH_MASS_MAX)
			_print_profile("launcher mass")
			return true
		KEY_EQUAL:
			launch_mass = clampf(launch_mass + adjusted_mass_step, _LAUNCH_MASS_MIN, _LAUNCH_MASS_MAX)
			_print_profile("launcher mass")
			return true
		KEY_COMMA:
			projectile_ttl_seconds = clampf(projectile_ttl_seconds - adjusted_ttl_step, _TTL_MIN, _TTL_MAX)
			_print_profile("projectile ttl")
			return true
		KEY_PERIOD:
			projectile_ttl_seconds = clampf(projectile_ttl_seconds + adjusted_ttl_step, _TTL_MIN, _TTL_MAX)
			_print_profile("projectile ttl")
			return true
		KEY_SLASH:
			launch_energy_scale = clampf(launch_energy_scale - adjusted_energy_step, _ENERGY_SCALE_MIN, _ENERGY_SCALE_MAX)
			_print_profile("impact multiplier")
			return true
		KEY_APOSTROPHE:
			launch_energy_scale = clampf(launch_energy_scale + adjusted_energy_step, _ENERGY_SCALE_MIN, _ENERGY_SCALE_MAX)
			_print_profile("impact multiplier")
			return true
		KEY_0:
			if key_event.ctrl_pressed:
				_print_profile("launcher profile")
				return true
			return false
	return false

func step(delta: float) -> void:
	_cooldown_remaining = maxf(0.0, _cooldown_remaining - delta)
	_prune_inactive()

func sample_active_projectile_contact_rows() -> Array:
	var sampled_rows: Array = []
	var rows := PhysicsServerContactBridgeScript.sample_contact_rows(_active_projectiles)
	if rows is Array:
		for row_variant in rows:
			if not (row_variant is Dictionary):
				continue
			_queue_projectile_contact_row(row_variant as Dictionary)
	var cursor_start := clampi(_sampled_contact_cursor, 0, _pending_contact_rows.size())
	for index in range(cursor_start, _pending_contact_rows.size()):
		var row_variant = _pending_contact_rows[index]
		if not (row_variant is Dictionary):
			continue
		sampled_rows.append((row_variant as Dictionary).duplicate(true))
	_sampled_contact_cursor = _pending_contact_rows.size()
	return sampled_rows

func record_projectile_contact_row(row: Dictionary) -> void:
	_queue_projectile_contact_row(row)

func sample_voxel_dispatch_contact_rows() -> Array:
	var sampled_rows: Array = []
	for row in _pending_contact_rows:
		sampled_rows.append(row.duplicate(true))
	return sampled_rows

func pending_voxel_dispatch_contact_count() -> int:
	return _pending_contact_rows.size()

func acknowledge_voxel_dispatch_contact_rows(consumed_count: int) -> void:
	var count := maxi(0, consumed_count)
	if count <= 0:
		return
	var remove_count := mini(count, _pending_contact_rows.size())
	if remove_count <= 0:
		return
	_pending_contact_rows = _pending_contact_rows.slice(remove_count, _pending_contact_rows.size())
	_sampled_contact_cursor = maxi(0, _sampled_contact_cursor - remove_count)

func try_fire_from_screen_center() -> bool:
	if _camera == null or not is_instance_valid(_camera):
		return false
	if _spawn_parent == null or not is_instance_valid(_spawn_parent):
		return false
	if not _camera.is_inside_tree() or not _spawn_parent.is_inside_tree():
		return false
	if _cooldown_remaining > 0.0:
		return false
	_prune_inactive()
	if _active_projectiles.size() >= maxi(1, max_active_projectiles):
		return false
	if projectile_scene == null:
		return false
	var projectile_node := projectile_scene.instantiate()
	if not (projectile_node is RigidBody3D):
		return false
	var projectile := projectile_node as RigidBody3D
	var viewport := _camera.get_viewport()
	if viewport == null:
		return false
	var center := viewport.get_visible_rect().size * 0.5
	var ray_origin := _camera.project_ray_origin(center)
	var ray_direction := _camera.project_ray_normal(center).normalized()
	_spawn_parent.add_child(projectile)
	var spawn_local := _spawn_parent.to_local(ray_origin + ray_direction * spawn_distance)
	projectile.position = spawn_local
	var speed_scale = launch_speed * launch_energy_scale
	projectile.mass = launch_mass
	projectile.linear_velocity = ray_direction * speed_scale
	projectile.continuous_cd = true
	if projectile.has_method("set_ttl_seconds"):
		projectile.call("set_ttl_seconds", projectile_ttl_seconds)
	if projectile.has_node("CollisionShape3D"):
		var collision = projectile.get_node("CollisionShape3D")
		if collision is CollisionShape3D and collision.shape is SphereShape3D:
			var adjusted_shape = SphereShape3D.new()
			adjusted_shape.radius = clampf(projectile_radius, _RADIUS_MIN, _RADIUS_MAX)
			collision.shape = adjusted_shape
	_active_projectiles.append(projectile)
	projectile.body_entered.connect(_on_projectile_body_entered.bind(projectile))
	projectile.tree_exited.connect(_on_projectile_tree_exited.bind(projectile), CONNECT_ONE_SHOT)
	_cooldown_remaining = cooldown_seconds
	return true

func _on_projectile_body_entered(hit_body: Node, projectile: RigidBody3D) -> void:
	if projectile == null or not is_instance_valid(projectile):
		return
	var projectile_velocity := projectile.linear_velocity
	var obstacle_velocity := Vector3.ZERO
	var obstacle_mask := 0
	var collider_id := 0
	var collider_mass := 0.0
	if hit_body != null and is_instance_valid(hit_body):
		collider_id = hit_body.get_instance_id()
		if hit_body is RigidBody3D:
			var rigid_hit := hit_body as RigidBody3D
			obstacle_velocity = rigid_hit.linear_velocity
			collider_mass = maxf(0.0, rigid_hit.mass)
		elif hit_body.has_method("get_linear_velocity"):
			var velocity_variant = hit_body.call("get_linear_velocity")
			if velocity_variant is Vector3:
				obstacle_velocity = velocity_variant as Vector3
		if hit_body.has_method("get_mass"):
			var mass_variant = hit_body.call("get_mass")
			if mass_variant is float or mass_variant is int:
				collider_mass = maxf(0.0, float(mass_variant))
		if hit_body is CollisionObject3D:
			obstacle_mask = int((hit_body as CollisionObject3D).collision_layer)
	var relative_velocity := projectile_velocity - obstacle_velocity
	var relative_speed := relative_velocity.length()
	var projectile_mass := maxf(0.01, projectile.mass)
	var contact_impulse := maxf(0.0, projectile_mass * relative_speed)
	var contact_normal := Vector3.ZERO
	if relative_speed > 0.001:
		contact_normal = (-relative_velocity).normalized()
	var contact_point := projectile.global_position
	var contact_row := {
		"body_id": projectile.get_instance_id(),
		"collider_id": collider_id,
		"contact_point": contact_point,
		"contact_normal": contact_normal,
		"contact_impulse": contact_impulse,
		"impulse": contact_impulse,
		"contact_velocity": relative_speed,
		"relative_speed": relative_speed,
		"body_velocity": projectile_velocity,
		"obstacle_velocity": obstacle_velocity,
		"body_mass": projectile_mass,
		"collider_mass": collider_mass,
		"rigid_obstacle_mask": obstacle_mask,
	}
	_queue_projectile_contact_row(contact_row)

func _queue_projectile_contact_row(row: Dictionary) -> void:
	if row.is_empty():
		return
	var impulse := maxf(0.0, float(row.get("contact_impulse", row.get("impulse", 0.0))))
	var relative_speed := maxf(0.0, float(row.get("relative_speed", row.get("contact_velocity", 0.0))))
	if impulse <= 0.0 and relative_speed <= 0.0:
		return
	var normalized := row.duplicate(true)
	normalized["contact_impulse"] = impulse
	normalized["impulse"] = impulse
	normalized["relative_speed"] = relative_speed
	normalized["contact_velocity"] = maxf(0.0, float(normalized.get("contact_velocity", relative_speed)))
	_pending_contact_rows.append(normalized)
	while _pending_contact_rows.size() > _MAX_PENDING_CONTACT_ROWS:
		_pending_contact_rows.remove_at(0)
		_sampled_contact_cursor = maxi(0, _sampled_contact_cursor - 1)

func _print_profile(trigger: String = "launcher profile") -> void:
	print("[Launcher] %s -> speed=%.1f mass=%.3f ttl=%.2f impact_scale=%.2f cooldown=%.2f active=%d" % [
		trigger,
		launch_speed,
		launch_mass,
		projectile_ttl_seconds,
		launch_energy_scale,
		cooldown_seconds,
		_active_projectiles.size()
	])

func _prune_inactive() -> void:
	for i in range(_active_projectiles.size() - 1, -1, -1):
		var projectile := _active_projectiles[i]
		if projectile == null or not is_instance_valid(projectile):
			_active_projectiles.remove_at(i)

func _on_projectile_tree_exited(projectile: RigidBody3D) -> void:
	_active_projectiles.erase(projectile)
