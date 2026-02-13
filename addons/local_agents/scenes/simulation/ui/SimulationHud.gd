extends CanvasLayer

signal play_pressed
signal pause_pressed
signal rewind_pressed
signal fast_forward_pressed
signal fork_pressed
signal inspector_npc_changed(npc_id)
signal overlays_changed(paths, resources, conflicts, smell, wind, temperature)

@onready var status_label: Label = %StatusLabel
@onready var details_label: Label = get_node_or_null("%DetailsLabel")
@onready var inspector_npc_edit: LineEdit = get_node_or_null("%InspectorNpcEdit")
@onready var path_toggle: CheckBox = get_node_or_null("%PathToggle")
@onready var resource_toggle: CheckBox = get_node_or_null("%ResourceToggle")
@onready var conflict_toggle: CheckBox = get_node_or_null("%ConflictToggle")
@onready var smell_toggle: CheckBox = get_node_or_null("%SmellToggle")
@onready var wind_toggle: CheckBox = get_node_or_null("%WindToggle")
@onready var temperature_toggle: CheckBox = get_node_or_null("%TemperatureToggle")

func set_status_text(text: String) -> void:
	status_label.text = text

func set_details_text(text: String) -> void:
	if details_label == null:
		return
	details_label.text = text

func _on_play_button_pressed() -> void:
	emit_signal("play_pressed")

func _on_pause_button_pressed() -> void:
	emit_signal("pause_pressed")

func _on_rewind_button_pressed() -> void:
	emit_signal("rewind_pressed")

func _on_fast_forward_button_pressed() -> void:
	emit_signal("fast_forward_pressed")

func _on_fork_button_pressed() -> void:
	emit_signal("fork_pressed")

func set_inspector_npc(npc_id: String) -> void:
	if inspector_npc_edit == null:
		return
	if inspector_npc_edit.text == npc_id:
		return
	inspector_npc_edit.text = npc_id

func _on_inspector_npc_edit_text_submitted(new_text: String) -> void:
	emit_signal("inspector_npc_changed", String(new_text).strip_edges())

func _on_inspector_apply_button_pressed() -> void:
	if inspector_npc_edit == null:
		return
	emit_signal("inspector_npc_changed", String(inspector_npc_edit.text).strip_edges())

func _on_overlay_toggled(_pressed: bool) -> void:
	emit_signal(
		"overlays_changed",
		path_toggle != null and path_toggle.button_pressed,
		resource_toggle != null and resource_toggle.button_pressed,
		conflict_toggle != null and conflict_toggle.button_pressed,
		smell_toggle != null and smell_toggle.button_pressed,
		wind_toggle != null and wind_toggle.button_pressed,
		temperature_toggle != null and temperature_toggle.button_pressed
	)
