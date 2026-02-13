extends RefCounted

var _hud: CanvasLayer
var _inspector_npc_edit: LineEdit
var _path_toggle: CheckBox
var _resource_toggle: CheckBox
var _conflict_toggle: CheckBox
var _smell_toggle: CheckBox
var _wind_toggle: CheckBox
var _temperature_toggle: CheckBox

var _emit_inspector_npc_changed: Callable
var _emit_overlays_changed: Callable

func configure(hud: CanvasLayer, emit_inspector_npc_changed: Callable, emit_overlays_changed: Callable) -> void:
	_hud = hud
	_emit_inspector_npc_changed = emit_inspector_npc_changed
	_emit_overlays_changed = emit_overlays_changed
	_inspector_npc_edit = _hud.get_node_or_null("%InspectorNpcEdit") as LineEdit
	_path_toggle = _hud.get_node_or_null("%PathToggle") as CheckBox
	_resource_toggle = _hud.get_node_or_null("%ResourceToggle") as CheckBox
	_conflict_toggle = _hud.get_node_or_null("%ConflictToggle") as CheckBox
	_smell_toggle = _hud.get_node_or_null("%SmellToggle") as CheckBox
	_wind_toggle = _hud.get_node_or_null("%WindToggle") as CheckBox
	_temperature_toggle = _hud.get_node_or_null("%TemperatureToggle") as CheckBox

func set_inspector_npc(npc_id: String) -> void:
	if _inspector_npc_edit == null:
		return
	if _inspector_npc_edit.text == npc_id:
		return
	_inspector_npc_edit.text = npc_id

func on_inspector_npc_edit_text_submitted(new_text: String) -> void:
	if _emit_inspector_npc_changed.is_valid():
		_emit_inspector_npc_changed.call(String(new_text).strip_edges())

func on_inspector_apply_button_pressed() -> void:
	if _inspector_npc_edit == null:
		return
	if _emit_inspector_npc_changed.is_valid():
		_emit_inspector_npc_changed.call(String(_inspector_npc_edit.text).strip_edges())

func on_overlay_toggled() -> void:
	if not _emit_overlays_changed.is_valid():
		return
	_emit_overlays_changed.call(
		_path_toggle != null and _path_toggle.button_pressed,
		_resource_toggle != null and _resource_toggle.button_pressed,
		_conflict_toggle != null and _conflict_toggle.button_pressed,
		_smell_toggle != null and _smell_toggle.button_pressed,
		_wind_toggle != null and _wind_toggle.button_pressed,
		_temperature_toggle != null and _temperature_toggle.button_pressed
	)
