extends Node3D

@onready var ecology_controller: Node3D = $EcologyController
@onready var debug_overlay: Node3D = $DebugOverlayRoot
@onready var camera: Camera3D = $Camera3D
@onready var field_hud: CanvasLayer = $FieldHud

@export var orbit_sensitivity: float = 0.007
@export var pan_sensitivity: float = 0.01
@export var zoom_step_ratio: float = 0.1
@export var min_zoom_distance: float = 3.0
@export var max_zoom_distance: float = 40.0
@export var min_pitch_degrees: float = 18.0
@export var max_pitch_degrees: float = 82.0

var _spawn_mode: String = "none"
var _camera_focus: Vector3 = Vector3.ZERO
var _camera_distance: float = 16.0
var _camera_yaw: float = 0.0
var _camera_pitch: float = deg_to_rad(55.0)
var _mmb_down: bool = false
var _rmb_down: bool = false

func _ready() -> void:
	_initialize_camera_orbit()
	if ecology_controller.has_method("set_debug_overlay"):
		ecology_controller.call("set_debug_overlay", debug_overlay)
	if field_hud.has_signal("spawn_mode_requested"):
		field_hud.connect("spawn_mode_requested", _on_spawn_mode_requested)
	if field_hud.has_signal("spawn_random_requested"):
		field_hud.connect("spawn_random_requested", _on_spawn_random_requested)
	if field_hud.has_signal("debug_settings_changed"):
		field_hud.connect("debug_settings_changed", _on_debug_settings_changed)
	field_hud.call("set_spawn_mode", _spawn_mode)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey:
		var key_event := event as InputEventKey
		if key_event.pressed and key_event.keycode == KEY_ESCAPE and _spawn_mode != "none":
			_set_spawn_mode("none", "Selection mode restored")
			return

	if event is InputEventMouseMotion:
		_handle_camera_mouse_motion(event as InputEventMouseMotion)
		return

	if event is InputEventMouseButton:
		var mouse_event := event as InputEventMouseButton
		if mouse_event.button_index == MOUSE_BUTTON_RIGHT and mouse_event.pressed and _spawn_mode != "none":
			_rmb_down = false
			_set_spawn_mode("none", "Selection mode restored")
			return
		if _handle_camera_mouse_button(mouse_event):
			return
		if mouse_event.button_index != MOUSE_BUTTON_LEFT or not mouse_event.pressed:
			return
		if _spawn_mode != "none":
			_handle_spawn_click(mouse_event.position)
			return
		_handle_select_click(mouse_event.position)

func _on_spawn_mode_requested(mode: String) -> void:
	_set_spawn_mode(mode)

func _on_spawn_random_requested(plants: int, rabbits: int) -> void:
	if ecology_controller.has_method("spawn_random"):
		ecology_controller.call("spawn_random", plants, rabbits)
	field_hud.call("set_status", "Spawned random: %d plants, %d rabbits" % [plants, rabbits])

func _on_debug_settings_changed(settings: Dictionary) -> void:
	if ecology_controller.has_method("apply_debug_settings"):
		ecology_controller.call("apply_debug_settings", settings)

func _handle_spawn_click(screen_pos: Vector2) -> void:
	var mode_used := _spawn_mode
	var point = _screen_to_ground(screen_pos)
	if point == null:
		return
	var spawned: Variant = null
	if _spawn_mode == "plant" and ecology_controller.has_method("spawn_plant_at"):
		spawned = ecology_controller.call("spawn_plant_at", point, 0.0)
	elif _spawn_mode == "rabbit" and ecology_controller.has_method("spawn_rabbit_at"):
		spawned = ecology_controller.call("spawn_rabbit_at", point)
	if spawned != null and spawned is Node and spawned.has_method("get_inspector_payload"):
		field_hud.call("show_inspector", spawned.call("get_inspector_payload"))
	_set_spawn_mode("none", "Spawned %s. Selection mode restored" % mode_used)

func _handle_select_click(screen_pos: Vector2) -> void:
	var origin := camera.project_ray_origin(screen_pos)
	var direction := camera.project_ray_normal(screen_pos)
	var query := PhysicsRayQueryParameters3D.create(origin, origin + direction * 400.0)
	query.collide_with_areas = true
	query.collide_with_bodies = true
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		field_hud.call("clear_inspector")
		field_hud.call("set_status", "Nothing selected")
		return
	var selectable := _resolve_selectable(hit.get("collider", null))
	if selectable == null:
		field_hud.call("clear_inspector")
		field_hud.call("set_status", "Nothing selectable")
		return
	if selectable.has_method("get_inspector_payload"):
		field_hud.call("show_inspector", selectable.call("get_inspector_payload"))
	field_hud.call("set_status", "Selected %s" % selectable.name)

func _resolve_selectable(collider: Variant) -> Node:
	if collider == null or not (collider is Node):
		return null
	var node: Node = collider
	while node != null and node != self:
		if node.has_method("get_inspector_payload"):
			return node
		node = node.get_parent()
	return null

func _screen_to_ground(screen_pos: Vector2) -> Variant:
	var origin := camera.project_ray_origin(screen_pos)
	var direction := camera.project_ray_normal(screen_pos)
	var hit = Plane(Vector3.UP, 0.0).intersects_ray(origin, direction)
	if hit == null:
		return null
	return Vector3(hit)

func _initialize_camera_orbit() -> void:
	var default_focus := _screen_to_ground(get_viewport().get_visible_rect().size * 0.5)
	if default_focus != null:
		_camera_focus = Vector3(default_focus)
	_camera_focus.y = 0.0
	var offset := camera.global_position - _camera_focus
	_camera_distance = clampf(offset.length(), min_zoom_distance, max_zoom_distance)
	if _camera_distance > 0.001:
		_camera_pitch = clampf(asin(offset.y / _camera_distance), deg_to_rad(min_pitch_degrees), deg_to_rad(max_pitch_degrees))
		_camera_yaw = atan2(offset.x, offset.z)
	_apply_camera_transform()

func _handle_camera_mouse_button(event: InputEventMouseButton) -> bool:
	if event.button_index == MOUSE_BUTTON_MIDDLE:
		_mmb_down = event.pressed
		return true
	if event.button_index == MOUSE_BUTTON_RIGHT:
		_rmb_down = event.pressed
		return true
	if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
		_camera_distance = maxf(min_zoom_distance, _camera_distance * (1.0 - zoom_step_ratio))
		_apply_camera_transform()
		return true
	if event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
		_camera_distance = minf(max_zoom_distance, _camera_distance * (1.0 + zoom_step_ratio))
		_apply_camera_transform()
		return true
	return false

func _handle_camera_mouse_motion(event: InputEventMouseMotion) -> void:
	if not _mmb_down and not _rmb_down:
		return
	if _rmb_down or Input.is_key_pressed(KEY_SHIFT):
		_pan_camera(event.relative)
	else:
		_orbit_camera(event.relative)
	_apply_camera_transform()

func _orbit_camera(relative: Vector2) -> void:
	_camera_yaw -= relative.x * orbit_sensitivity
	_camera_pitch = clampf(
		_camera_pitch - relative.y * orbit_sensitivity,
		deg_to_rad(min_pitch_degrees),
		deg_to_rad(max_pitch_degrees)
	)

func _pan_camera(relative: Vector2) -> void:
	var right := camera.global_transform.basis.x
	right.y = 0.0
	if right.length_squared() > 0.0001:
		right = right.normalized()
	var forward := -camera.global_transform.basis.z
	forward.y = 0.0
	if forward.length_squared() > 0.0001:
		forward = forward.normalized()
	var scale := pan_sensitivity * _camera_distance
	_camera_focus += (-right * relative.x + forward * relative.y) * scale
	_camera_focus.y = 0.0

func _apply_camera_transform() -> void:
	var horizontal := cos(_camera_pitch) * _camera_distance
	var offset := Vector3(
		sin(_camera_yaw) * horizontal,
		sin(_camera_pitch) * _camera_distance,
		cos(_camera_yaw) * horizontal
	)
	camera.global_position = _camera_focus + offset
	camera.look_at(_camera_focus, Vector3.UP)

func _set_spawn_mode(mode: String, status_override: String = "") -> void:
	_spawn_mode = mode
	field_hud.call("set_spawn_mode", _spawn_mode)
	if status_override != "":
		field_hud.call("set_status", status_override)
		return
	if _spawn_mode == "none":
		field_hud.call("set_status", "Select mode active")
	else:
		field_hud.call("set_status", "Click ground to spawn %s" % _spawn_mode)
