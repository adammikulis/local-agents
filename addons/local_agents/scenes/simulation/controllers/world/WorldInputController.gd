extends RefCounted
class_name LocalAgentsWorldInputController

const _CAMERA_MODE_LABEL := "Mode: Camera (Press F)"
const _FPS_MODE_LABEL := "Mode: FPS (Press F)"

var _host: Node = null
var _simulation_hud: CanvasLayer = null
var _field_hud: CanvasLayer = null
var _get_spawn_mode_fn: Callable = Callable()
var _set_spawn_mode_fn: Callable = Callable()
var _fire_request_fn: Callable = Callable()
var _spawn_click_fn: Callable = Callable()
var _set_mode_label_fn: Callable = Callable()
var _handle_camera_mouse_motion_fn: Callable = Callable()
var _handle_camera_mouse_button_fn: Callable = Callable()
var _is_input_enabled: bool = true
var _is_fps_mode: bool = false

func configure(
	host: Node,
	simulation_hud: CanvasLayer,
	field_hud: CanvasLayer,
	get_spawn_mode_fn: Callable,
	set_spawn_mode_fn: Callable,
	fire_request_fn: Callable,
	spawn_click_fn: Callable,
	set_mode_label_fn: Callable,
	handle_camera_motion_fn: Callable,
	handle_camera_button_fn: Callable,
	is_input_enabled: bool = true
) -> void:
	_host = host
	_simulation_hud = simulation_hud
	_field_hud = field_hud
	_get_spawn_mode_fn = get_spawn_mode_fn
	_set_spawn_mode_fn = set_spawn_mode_fn
	_fire_request_fn = fire_request_fn
	_spawn_click_fn = spawn_click_fn
	_set_mode_label_fn = set_mode_label_fn
	_handle_camera_mouse_motion_fn = handle_camera_motion_fn
	_handle_camera_mouse_button_fn = handle_camera_button_fn
	_is_input_enabled = is_input_enabled
	_update_mode_label()

func set_input_enabled(enabled: bool) -> void:
	_is_input_enabled = enabled

func set_spawn_mode(mode: String) -> void:
	if _set_spawn_mode_fn.is_valid():
		_set_spawn_mode_fn.call(mode)

func get_spawn_mode() -> String:
	if not _get_spawn_mode_fn.is_valid():
		return "none"
	var mode_variant = _get_spawn_mode_fn.call()
	if mode_variant is String:
		return String(mode_variant)
	return "none"

func is_fps_mode() -> bool:
	return _is_fps_mode

func set_mode_label(text: String) -> void:
	if _set_mode_label_fn.is_valid():
		_set_mode_label_fn.call(text)

func refresh_mode_label() -> void:
	_update_mode_label()

func toggle_fps_mode() -> void:
	_is_fps_mode = not _is_fps_mode
	_update_mode_label()

func handle_unhandled_input(event: InputEvent) -> void:
	if not _is_input_enabled:
		return
	if event is InputEventMouseMotion:
		_handle_camera_motion(event as InputEventMouseMotion)
		return
	if event is InputEventMouseButton:
		_handle_mouse_button(event as InputEventMouseButton)
		return
	if event is InputEventKey:
		_handle_key_input(event as InputEventKey)
		return

func _handle_key_input(key_event: InputEventKey) -> void:
	if not key_event.pressed or key_event.echo:
		return
	if _is_text_ui_focus_active():
		return
	if key_event.keycode == KEY_F:
		toggle_fps_mode()
		return
	if key_event.keycode == KEY_SPACE:
		if _is_fps_mode and not _spawn_mode_active() and not _is_pointer_over_blocking_control():
			_fire_if_possible()
		return

func _handle_mouse_button(mouse_event: InputEventMouseButton) -> void:
	if _is_pointer_over_blocking_control(mouse_event.position):
		return
	_handle_camera_button(mouse_event)
	if not mouse_event.pressed:
		return
	if mouse_event.button_index != MOUSE_BUTTON_LEFT:
		return
	if _spawn_mode_active():
		_spawn_click(mouse_event.position)
		return
	if _is_fps_mode:
		_fire_if_possible()

func _handle_camera_motion(motion_event: InputEventMouseMotion) -> void:
	if _handle_camera_mouse_motion_fn.is_valid():
		_handle_camera_mouse_motion_fn.call(motion_event)

func _handle_camera_button(button_event: InputEventMouseButton) -> void:
	if _handle_camera_mouse_button_fn.is_valid():
		_handle_camera_mouse_button_fn.call(button_event)

func _spawn_mode_active() -> bool:
	return get_spawn_mode() != "none"

func _fire_if_possible() -> void:
	if not _fire_request_fn.is_valid():
		return
	_fire_request_fn.call()

func _spawn_click(screen_pos: Vector2) -> void:
	if _spawn_click_fn.is_valid():
		_spawn_click_fn.call(screen_pos)

func _is_pointer_over_blocking_control(screen_pos: Vector2 = Vector2.INF) -> bool:
	if _host == null:
		return false
	var hovered: Control = null
	var viewport = _host.get_viewport()
	if viewport == null:
		return false
	hovered = viewport.gui_get_hovered_control() as Control
	if hovered == null:
		return _is_interactive_control_at_position(screen_pos, _simulation_hud) or _is_interactive_control_at_position(screen_pos, _field_hud)
	if _simulation_hud != null and (_simulation_hud == hovered or _simulation_hud.is_ancestor_of(hovered)):
		return _has_interactive_control_in_hover_path(hovered, _simulation_hud)
	if _field_hud != null and (_field_hud == hovered or _field_hud.is_ancestor_of(hovered)):
		return _has_interactive_control_in_hover_path(hovered, _field_hud)
	return hovered != null and _is_interactive_control(hovered)

func _is_text_ui_focus_active() -> bool:
	if _host == null:
		return false
	var viewport = _host.get_viewport()
	if viewport == null:
		return false
	var focused: Object = viewport.gui_get_focus_owner()
	if not (focused is Control):
		return false
	return (focused as Control).focus_mode != Control.FOCUS_NONE

func _has_interactive_control_in_hover_path(hovered: Node, hud_root: Node) -> bool:
	var current: Node = hovered
	while current != null:
		if current == hud_root:
			if current is Control:
				return _is_interactive_control(current as Control)
			return false
		if current is Control and _is_interactive_control(current as Control):
			return true
		current = current.get_parent()
	return false

func _is_interactive_control(control: Control) -> bool:
	if control == null:
		return false
	if not control.visible or control.mouse_filter == Control.MOUSE_FILTER_IGNORE:
		return false
	if control is BaseButton or control is LineEdit or control is TextEdit:
		return true
	if control.focus_mode != Control.FOCUS_NONE:
		return true
	if control.has_signal("pressed") or control.has_signal("toggled") or control.has_signal("value_changed") or control.has_signal("text_submitted") or control.has_signal("item_selected"):
		return true
	return false

func _is_interactive_control_at_position(screen_pos: Vector2, node: Node) -> bool:
	if node == null:
		return false
	if node is Control:
		var control := node as Control
		if control.visible and _is_interactive_control(control) and control.get_global_rect().has_point(screen_pos):
			return true
	for child in node.get_children():
		if not (child is Node):
			continue
		if _is_interactive_control_at_position(screen_pos, child as Node):
			return true
	return false

func _update_mode_label() -> void:
	if _is_fps_mode:
		set_mode_label(_FPS_MODE_LABEL)
	else:
		set_mode_label(_CAMERA_MODE_LABEL)
