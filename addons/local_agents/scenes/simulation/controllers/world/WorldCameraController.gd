extends RefCounted
class_name LocalAgentsWorldCameraController

var _world_camera: Camera3D = null
var _orbit_sensitivity: float = 0.007
var _pan_sensitivity: float = 0.01
var _zoom_step_ratio: float = 0.1
var _min_zoom_distance: float = 3.0
var _max_zoom_distance: float = 120.0
var _min_pitch_radians: float = deg_to_rad(18.0)
var _max_pitch_radians: float = deg_to_rad(82.0)

var _camera_focus: Vector3 = Vector3.ZERO
var _camera_distance: float = 16.0
var _camera_yaw: float = 0.0
var _camera_pitch: float = deg_to_rad(55.0)
var _mmb_down: bool = false
var _rmb_down: bool = false
var _fps_mode_enabled: bool = false
var _fps_look_sensitivity: float = 0.0035
var _fps_move_speed: float = 18.0
var _fps_vertical_speed: float = 18.0
var _fps_yaw: float = PI
var _fps_pitch: float = 0.0
var _fps_min_pitch_radians: float = deg_to_rad(-89.0)
var _fps_max_pitch_radians: float = deg_to_rad(89.0)

func configure(
	world_camera: Camera3D,
	orbit_sensitivity: float,
	pan_sensitivity: float,
	zoom_step_ratio: float,
	min_zoom_distance: float,
	max_zoom_distance: float,
	min_pitch_degrees: float,
	max_pitch_degrees: float
) -> void:
	_world_camera = world_camera
	_orbit_sensitivity = orbit_sensitivity
	_pan_sensitivity = pan_sensitivity
	_zoom_step_ratio = zoom_step_ratio
	_min_zoom_distance = min_zoom_distance
	_max_zoom_distance = max_zoom_distance
	_min_pitch_radians = deg_to_rad(min_pitch_degrees)
	_max_pitch_radians = deg_to_rad(max_pitch_degrees)

func initialize_orbit() -> void:
	if _world_camera == null:
		return
	_camera_focus = Vector3.ZERO
	rebuild_orbit_state_from_camera()

func frame_from_environment(environment_snapshot: Dictionary) -> void:
	if _world_camera == null or environment_snapshot.is_empty():
		return
	var width = float(environment_snapshot.get("width", 1))
	var depth = float(environment_snapshot.get("height", 1))
	var voxel_world: Dictionary = environment_snapshot.get("voxel_world", {})
	var world_height = float(voxel_world.get("height", 24))
	var center = Vector3(width * 0.5, world_height * 0.35, depth * 0.5)
	var distance = maxf(width, depth) * 1.05
	_world_camera.position = center + Vector3(distance * 0.75, world_height * 0.6 + 10.0, distance)
	_world_camera.look_at(center, Vector3.UP)
	_camera_focus = center
	rebuild_orbit_state_from_camera()

func rebuild_orbit_state_from_camera() -> void:
	if _world_camera == null:
		return
	var offset := _world_camera.global_position - _camera_focus
	_camera_distance = clampf(offset.length(), _min_zoom_distance, _max_zoom_distance)
	if _camera_distance > 0.001:
		_camera_pitch = clampf(asin(offset.y / _camera_distance), _min_pitch_radians, _max_pitch_radians)
		_camera_yaw = atan2(offset.x, offset.z)

func handle_mouse_button(event: InputEventMouseButton) -> void:
	if _fps_mode_enabled:
		return
	if event.button_index == MOUSE_BUTTON_MIDDLE:
		_mmb_down = event.pressed
		return
	if event.button_index == MOUSE_BUTTON_RIGHT:
		_rmb_down = event.pressed
		return
	if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
		_camera_distance = maxf(_min_zoom_distance, _camera_distance * (1.0 - _zoom_step_ratio))
		apply_camera_transform()
		return
	if event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
		_camera_distance = minf(_max_zoom_distance, _camera_distance * (1.0 + _zoom_step_ratio))
		apply_camera_transform()

func handle_mouse_motion(event: InputEventMouseMotion) -> void:
	if _fps_mode_enabled:
		_fps_yaw -= event.relative.x * _fps_look_sensitivity
		_fps_pitch = clampf(_fps_pitch - event.relative.y * _fps_look_sensitivity, _fps_min_pitch_radians, _fps_max_pitch_radians)
		_apply_fps_look_transform()
		return
	if not Input.is_key_pressed(KEY_CTRL):
		return
	if not _mmb_down and not _rmb_down:
		return
	if _rmb_down or Input.is_key_pressed(KEY_SHIFT):
		pan_camera(event.relative)
	else:
		orbit_camera(event.relative)
	apply_camera_transform()

func set_fps_mode(enabled: bool) -> void:
	if _world_camera == null:
		_fps_mode_enabled = enabled
		return
	if enabled == _fps_mode_enabled:
		if enabled:
			_sync_fps_angles_from_camera()
		return
	if enabled:
		_sync_fps_angles_from_camera()
	else:
		_sync_orbit_state_from_camera_pose()
	_fps_mode_enabled = enabled
	_mmb_down = false
	_rmb_down = false

func step_fps(delta: float, input_override: Dictionary = {}) -> void:
	if not _fps_mode_enabled or _world_camera == null:
		return
	var is_key_pressed := func(keycode: int) -> bool:
		if input_override.has(keycode):
			return bool(input_override.get(keycode, false))
		return Input.is_key_pressed(keycode)
	var camera_basis := _world_camera.global_transform.basis.orthonormalized()
	var forward := -camera_basis.z
	if forward.length_squared() > 0.0001:
		forward = forward.normalized()
	var right := camera_basis.x
	if right.length_squared() > 0.0001:
		right = right.normalized()
	var move_direction := Vector3.ZERO
	if is_key_pressed.call(KEY_W):
		move_direction += forward
	if is_key_pressed.call(KEY_S):
		move_direction -= forward
	if is_key_pressed.call(KEY_D):
		move_direction += right
	if is_key_pressed.call(KEY_A):
		move_direction -= right
	if is_key_pressed.call(KEY_SHIFT):
		move_direction += Vector3.UP
	if is_key_pressed.call(KEY_CTRL):
		move_direction -= Vector3.UP
	if move_direction.length_squared() <= 0.0:
		return
	move_direction = move_direction.normalized()
	var speed := _fps_vertical_speed if absf(move_direction.dot(Vector3.UP)) > 0.5 else _fps_move_speed
	_world_camera.global_position += move_direction * speed * maxf(delta, 0.0)

func _sync_fps_angles_from_camera() -> void:
	if _world_camera == null:
		return
	var forward := -_world_camera.global_transform.basis.z
	if forward.length_squared() <= 0.0001:
		return
	forward = forward.normalized()
	_fps_pitch = clampf(asin(forward.y), _fps_min_pitch_radians, _fps_max_pitch_radians)
	var horizontal_len := Vector2(forward.x, forward.z).length()
	if horizontal_len > 0.0001:
		_fps_yaw = atan2(forward.x, forward.z)
	_apply_fps_look_transform()

func _sync_orbit_state_from_camera_pose() -> void:
	if _world_camera == null:
		return
	_sync_fps_angles_from_camera()
	_camera_pitch = clampf(_fps_pitch, _min_pitch_radians, _max_pitch_radians)
	_camera_yaw = _fps_yaw
	var horizontal := cos(_camera_pitch) * _camera_distance
	var offset := Vector3(
		sin(_camera_yaw) * horizontal,
		sin(_camera_pitch) * _camera_distance,
		cos(_camera_yaw) * horizontal
	)
	_camera_focus = _world_camera.global_position - offset

func _apply_fps_look_transform() -> void:
	if _world_camera == null:
		return
	var cos_pitch := cos(_fps_pitch)
	var forward := Vector3(
		sin(_fps_yaw) * cos_pitch,
		sin(_fps_pitch),
		cos(_fps_yaw) * cos_pitch
	)
	_world_camera.look_at(_world_camera.global_position + forward, Vector3.UP)

func orbit_camera(relative: Vector2) -> void:
	_camera_yaw -= relative.x * _orbit_sensitivity
	_camera_pitch = clampf(_camera_pitch - relative.y * _orbit_sensitivity, _min_pitch_radians, _max_pitch_radians)

func pan_camera(relative: Vector2) -> void:
	if _world_camera == null:
		return
	var right := _world_camera.global_transform.basis.x
	right.y = 0.0
	if right.length_squared() > 0.0001:
		right = right.normalized()
	var forward := -_world_camera.global_transform.basis.z
	forward.y = 0.0
	if forward.length_squared() > 0.0001:
		forward = forward.normalized()
	var scale := _pan_sensitivity * _camera_distance
	_camera_focus += (-right * relative.x + forward * relative.y) * scale
	_camera_focus.y = maxf(0.0, _camera_focus.y)

func apply_camera_transform() -> void:
	if _world_camera == null:
		return
	var horizontal := cos(_camera_pitch) * _camera_distance
	var offset := Vector3(
		sin(_camera_yaw) * horizontal,
		sin(_camera_pitch) * _camera_distance,
		cos(_camera_yaw) * horizontal
	)
	_world_camera.global_position = _camera_focus + offset
	_world_camera.look_at(_camera_focus, Vector3.UP)

func native_view_metrics() -> Dictionary:
	var zoom_factor := 0.0
	var denom := maxf(0.001, _max_zoom_distance - _min_zoom_distance)
	zoom_factor = clampf((_camera_distance - _min_zoom_distance) / denom, 0.0, 1.0)
	return {
		"camera_distance": _camera_distance,
		"zoom_factor": zoom_factor,
	}

func screen_to_ground(screen_pos: Vector2) -> Variant:
	if _world_camera == null:
		return null
	var origin := _world_camera.project_ray_origin(screen_pos)
	var direction := _world_camera.project_ray_normal(screen_pos)
	var hit = Plane(Vector3.UP, 0.0).intersects_ray(origin, direction)
	if hit == null:
		return null
	return Vector3(hit)
