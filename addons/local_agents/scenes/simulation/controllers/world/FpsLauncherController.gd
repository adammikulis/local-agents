extends Node
class_name FpsLauncherController

const FpsLauncherProfileResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/FpsLauncherProfileResource.gd")

class ChunkProjectileState:
	extends RefCounted

	var projectile_id: int = 0
	var position: Vector3 = Vector3.ZERO
	var velocity: Vector3 = Vector3.ZERO
	var radius: float = 0.07
	var mass: float = 0.2
	var ttl_seconds: float = 4.0
	var material_tag: String = "dense_voxel"
	var hardness_tag: String = "hard"

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
@export var projectile_material_tag: String = "dense_voxel"
@export var projectile_hardness_tag: String = "hard"

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
const _MAX_PENDING_CONTACT_ROWS := 96

var _camera: Camera3D = null
var _spawn_parent: Node3D = null
var _cooldown_remaining: float = 0.0
var _active_projectiles: Array[ChunkProjectileState] = []
var _pending_contact_rows: Array[Dictionary] = []
var _sampled_contact_cursor: int = 0
var _next_projectile_id: int = 1

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
	if delta <= 0.0:
		return
	_advance_projectiles(delta)

func sample_active_projectile_contact_rows() -> Array:
	var sampled_rows: Array = []
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
	if _active_projectiles.size() >= maxi(1, max_active_projectiles):
		return false
	var viewport := _camera.get_viewport()
	if viewport == null:
		return false
	var center := viewport.get_visible_rect().size * 0.5
	var ray_origin := _camera.project_ray_origin(center)
	var ray_direction := _camera.project_ray_normal(center).normalized()
	if ray_direction == Vector3.ZERO:
		return false

	var projectile := ChunkProjectileState.new()
	projectile.projectile_id = _next_projectile_id
	_next_projectile_id += 1
	projectile.position = ray_origin + ray_direction * spawn_distance
	projectile.velocity = ray_direction * (launch_speed * launch_energy_scale)
	projectile.radius = clampf(projectile_radius, _RADIUS_MIN, _RADIUS_MAX)
	projectile.mass = clampf(launch_mass, _LAUNCH_MASS_MIN, _LAUNCH_MASS_MAX)
	projectile.ttl_seconds = clampf(projectile_ttl_seconds, _TTL_MIN, _TTL_MAX)
	projectile.material_tag = projectile_material_tag
	projectile.hardness_tag = projectile_hardness_tag
	_active_projectiles.append(projectile)
	_cooldown_remaining = cooldown_seconds
	return true

func _advance_projectiles(delta: float) -> void:
	var space_state := _physics_space_state()
	for i in range(_active_projectiles.size() - 1, -1, -1):
		var projectile := _active_projectiles[i]
		if projectile == null:
			_active_projectiles.remove_at(i)
			continue
		projectile.ttl_seconds -= delta
		if projectile.ttl_seconds <= 0.0:
			_active_projectiles.remove_at(i)
			continue
		var start := projectile.position
		var end := start + projectile.velocity * delta
		if space_state == null:
			projectile.position = end
			continue
		var hit := _intersect_segment(space_state, start, end)
		if hit.is_empty():
			projectile.position = end
			continue
		_queue_projectile_contact_row(_build_contact_row(projectile, hit, end))
		_active_projectiles.remove_at(i)

func _physics_space_state() -> PhysicsDirectSpaceState3D:
	var viewport := get_viewport()
	if viewport == null:
		return null
	var world := viewport.world_3d
	if world == null:
		return null
	return world.direct_space_state

func _intersect_segment(space_state: PhysicsDirectSpaceState3D, from_point: Vector3, to_point: Vector3) -> Dictionary:
	var query := PhysicsRayQueryParameters3D.create(from_point, to_point)
	query.collide_with_bodies = true
	query.collide_with_areas = true
	var excludes: Array[RID] = _build_query_excludes()
	if not excludes.is_empty():
		query.exclude = excludes
	var result = space_state.intersect_ray(query)
	if result is Dictionary:
		return result as Dictionary
	return {}

func _build_query_excludes() -> Array[RID]:
	var excludes: Array[RID] = []
	if _spawn_parent != null and is_instance_valid(_spawn_parent) and _spawn_parent is CollisionObject3D:
		excludes.append((_spawn_parent as CollisionObject3D).get_rid())
	return excludes

func _build_contact_row(projectile: ChunkProjectileState, hit: Dictionary, fallback_position: Vector3) -> Dictionary:
	var collider := hit.get("collider")
	var obstacle_velocity := Vector3.ZERO
	var obstacle_mask := 0
	var collider_id := int(hit.get("collider_id", 0))
	var collider_mass := 0.0
	if collider is CollisionObject3D:
		obstacle_mask = int((collider as CollisionObject3D).collision_layer)
	if collider is RigidBody3D:
		var rigid := collider as RigidBody3D
		obstacle_velocity = rigid.linear_velocity
		collider_mass = maxf(0.0, rigid.mass)
	elif collider != null and is_instance_valid(collider) and collider.has_method("get_linear_velocity"):
		var velocity_variant = collider.call("get_linear_velocity")
		if velocity_variant is Vector3:
			obstacle_velocity = velocity_variant as Vector3
	if collider != null and is_instance_valid(collider) and collider.has_method("get_mass"):
		var mass_variant = collider.call("get_mass")
		if mass_variant is float or mass_variant is int:
			collider_mass = maxf(collider_mass, float(mass_variant))

	var relative_velocity := projectile.velocity - obstacle_velocity
	var relative_speed := relative_velocity.length()
	var projectile_mass := maxf(0.01, projectile.mass)
	var contact_impulse := maxf(0.0, projectile_mass * relative_speed)
	var contact_normal := hit.get("normal", Vector3.ZERO)
	if not (contact_normal is Vector3):
		contact_normal = Vector3.ZERO
	if (contact_normal as Vector3) == Vector3.ZERO and relative_speed > 0.001:
		contact_normal = (-relative_velocity).normalized()
	var contact_point := hit.get("position", fallback_position)
	if not (contact_point is Vector3):
		contact_point = fallback_position
	if collider_id == 0 and collider != null and is_instance_valid(collider):
		collider_id = collider.get_instance_id()

	return {
		"body_id": projectile.projectile_id,
		"collider_id": collider_id,
		"contact_point": contact_point,
		"contact_normal": contact_normal,
		"contact_impulse": contact_impulse,
		"impulse": contact_impulse,
		"contact_velocity": relative_speed,
		"relative_speed": relative_speed,
		"body_velocity": projectile.velocity,
		"obstacle_velocity": obstacle_velocity,
		"body_mass": projectile_mass,
		"collider_mass": collider_mass,
		"rigid_obstacle_mask": obstacle_mask,
		"projectile_kind": "voxel_chunk",
		"projectile_density_tag": "dense",
		"projectile_hardness_tag": projectile.hardness_tag,
		"projectile_material_tag": projectile.material_tag,
		"failure_emission_profile": "dense_hard_voxel_chunk",
		"projectile_radius": projectile.radius,
		"projectile_ttl": projectile.ttl_seconds,
	}

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
	normalized["projectile_kind"] = String(normalized.get("projectile_kind", "voxel_chunk"))
	normalized["projectile_density_tag"] = String(normalized.get("projectile_density_tag", "dense"))
	normalized["projectile_hardness_tag"] = String(normalized.get("projectile_hardness_tag", projectile_hardness_tag))
	normalized["projectile_material_tag"] = String(normalized.get("projectile_material_tag", projectile_material_tag))
	normalized["failure_emission_profile"] = String(normalized.get("failure_emission_profile", "dense_hard_voxel_chunk"))
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
		_active_projectiles.size(),
	])
