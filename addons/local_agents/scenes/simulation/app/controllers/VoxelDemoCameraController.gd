extends RefCounted
class_name LocalAgentsVoxelDemoCameraController

var _camera: Camera3D
var _focus: Vector3 = Vector3.ZERO
var _distance: float = 32.0
var _yaw: float = 0.0
var _pitch: float = deg_to_rad(48.0)
var _orbit_drag: bool = false
var _pan_drag: bool = false
var _orbit_sensitivity: float = 0.008
var _pan_sensitivity: float = 0.0028
var _keyboard_speed: float = 24.0
var _min_zoom: float = 8.0
var _max_zoom: float = 340.0

func configure(camera: Camera3D) -> void:
	_camera = camera
	initialize_orbit()

func initialize_orbit() -> void:
	if _camera == null:
		return
	_focus = Vector3.ZERO
	_rebuild_orbit_state_from_camera()

func frame_world(world: Dictionary) -> void:
	if _camera == null:
		return
	var width = float(world.get("width", 1))
	var depth = float(world.get("height", 1))
	var voxel_world: Dictionary = world.get("voxel_world", {})
	var world_height = float(voxel_world.get("height", 24))
	var center = Vector3(width * 0.5, world_height * 0.35, depth * 0.5)
	var distance = maxf(width, depth) * 1.05
	_focus = center
	_distance = clampf(distance * 1.08, _min_zoom, _max_zoom)
	_yaw = deg_to_rad(36.0)
	_pitch = deg_to_rad(33.0)
	_apply_camera_transform()

func process(delta: float) -> void:
	if _camera == null:
		return
	if _orbit_drag or _pan_drag:
		return
	var axis = Vector3.ZERO
	if Input.is_key_pressed(KEY_A):
		axis.x -= 1.0
	if Input.is_key_pressed(KEY_D):
		axis.x += 1.0
	if Input.is_key_pressed(KEY_W):
		axis.z -= 1.0
	if Input.is_key_pressed(KEY_S):
		axis.z += 1.0
	if Input.is_key_pressed(KEY_Q):
		axis.y -= 1.0
	if Input.is_key_pressed(KEY_E):
		axis.y += 1.0
	if axis.length_squared() <= 0.00001:
		return
	var right = _camera.global_transform.basis.x
	var forward = -_camera.global_transform.basis.z
	forward.y = 0.0
	if forward.length_squared() > 0.00001:
		forward = forward.normalized()
	right.y = 0.0
	if right.length_squared() > 0.00001:
		right = right.normalized()
	var move = (right * axis.x + forward * axis.z + Vector3.UP * axis.y).normalized()
	_focus += move * _keyboard_speed * maxf(0.0, delta)
	_focus.y = maxf(0.0, _focus.y)
	_apply_camera_transform()

func handle_input(event: InputEvent) -> bool:
	if _camera == null:
		return false
	if event is InputEventMouseButton:
		var mouse_button = event as InputEventMouseButton
		if mouse_button.button_index == MOUSE_BUTTON_RIGHT:
			_orbit_drag = mouse_button.pressed
			return true
		if mouse_button.button_index == MOUSE_BUTTON_MIDDLE:
			_pan_drag = mouse_button.pressed
			return true
		if mouse_button.pressed and mouse_button.button_index == MOUSE_BUTTON_WHEEL_UP:
			_distance = maxf(_min_zoom, _distance * 0.9)
			_apply_camera_transform()
			return true
		if mouse_button.pressed and mouse_button.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_distance = minf(_max_zoom, _distance * 1.1)
			_apply_camera_transform()
			return true
	elif event is InputEventMouseMotion:
		var motion = event as InputEventMouseMotion
		if _orbit_drag:
			_yaw -= motion.relative.x * _orbit_sensitivity
			_pitch = clampf(_pitch - motion.relative.y * _orbit_sensitivity, deg_to_rad(8.0), deg_to_rad(85.0))
			_apply_camera_transform()
			return true
		if _pan_drag:
			var right = _camera.global_transform.basis.x
			var forward = -_camera.global_transform.basis.z
			forward.y = 0.0
			if forward.length_squared() > 0.00001:
				forward = forward.normalized()
			var scale = _pan_sensitivity * _distance
			_focus += (-right * motion.relative.x + forward * motion.relative.y) * scale
			_focus.y = maxf(0.0, _focus.y)
			_apply_camera_transform()
			return true
	return false

func _rebuild_orbit_state_from_camera() -> void:
	if _camera == null:
		return
	var offset = _camera.global_position - _focus
	_distance = clampf(offset.length(), _min_zoom, _max_zoom)
	if _distance <= 0.001:
		return
	_pitch = clampf(asin(offset.y / _distance), deg_to_rad(8.0), deg_to_rad(85.0))
	_yaw = atan2(offset.x, offset.z)

func _apply_camera_transform() -> void:
	if _camera == null:
		return
	var horizontal = cos(_pitch) * _distance
	var offset = Vector3(
		sin(_yaw) * horizontal,
		sin(_pitch) * _distance,
		cos(_yaw) * horizontal
	)
	_camera.global_position = _focus + offset
	_camera.look_at(_focus, Vector3.UP)
