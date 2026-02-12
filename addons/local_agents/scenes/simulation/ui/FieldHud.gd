extends CanvasLayer

signal spawn_mode_requested(mode: String)
signal spawn_random_requested(plants: int, rabbits: int)
signal debug_settings_changed(settings: Dictionary)

@onready var inspector_title_label: Label = $RootControl/InspectorPanel/InspectorMargin/InspectorVBox/InspectorTitle
@onready var inspector_text_label: RichTextLabel = $RootControl/InspectorPanel/InspectorMargin/InspectorVBox/InspectorText
@onready var status_label: Label = $RootControl/BottomPanel/BottomMargin/BottomVBox/StatusLabel
@onready var spawn_plant_button: Button = $RootControl/BottomPanel/BottomMargin/BottomVBox/ControlsRow/SpawnPlantButton
@onready var spawn_rabbit_button: Button = $RootControl/BottomPanel/BottomMargin/BottomVBox/ControlsRow/SpawnRabbitButton
@onready var select_button: Button = $RootControl/BottomPanel/BottomMargin/BottomVBox/ControlsRow/SelectButton
@onready var random_button: Button = $RootControl/BottomPanel/BottomMargin/BottomVBox/ControlsRow/SpawnRandomButton
@onready var plants_spin_box: SpinBox = $RootControl/BottomPanel/BottomMargin/BottomVBox/ControlsRow/RandomPlantsSpinBox
@onready var rabbits_spin_box: SpinBox = $RootControl/BottomPanel/BottomMargin/BottomVBox/ControlsRow/RandomRabbitsSpinBox
@onready var metrics_label: Label = $RootControl/BottomPanel/BottomMargin/BottomVBox/MetricsLabel
@onready var show_smell_check: CheckButton = $RootControl/BottomPanel/BottomMargin/BottomVBox/DebugRow/ShowSmellCheck
@onready var show_wind_check: CheckButton = $RootControl/BottomPanel/BottomMargin/BottomVBox/DebugRow/ShowWindCheck
@onready var show_temp_check: CheckButton = $RootControl/BottomPanel/BottomMargin/BottomVBox/DebugRow/ShowTempCheck
@onready var smell_layer_option: OptionButton = $RootControl/BottomPanel/BottomMargin/BottomVBox/DebugRow/SmellLayerOption

const SMELL_LAYER_OPTIONS := [
	{"id": "all", "label": "All"},
	{"id": "food", "label": "Food Attractants"},
	{"id": "floral", "label": "Floral"},
	{"id": "danger", "label": "Danger"},
	{"id": "hexanal", "label": "Hexanal"},
	{"id": "methyl_salicylate", "label": "Methyl Salicylate"},
]

func _ready() -> void:
	select_button.pressed.connect(func() -> void:
		emit_signal("spawn_mode_requested", "none")
	)
	spawn_plant_button.pressed.connect(func() -> void:
		emit_signal("spawn_mode_requested", "plant")
	)
	spawn_rabbit_button.pressed.connect(func() -> void:
		emit_signal("spawn_mode_requested", "rabbit")
	)
	random_button.pressed.connect(func() -> void:
		emit_signal("spawn_random_requested", int(plants_spin_box.value), int(rabbits_spin_box.value))
	)
	_setup_debug_options()
	show_smell_check.toggled.connect(func(_enabled: bool) -> void:
		_emit_debug_settings()
	)
	show_wind_check.toggled.connect(func(_enabled: bool) -> void:
		_emit_debug_settings()
	)
	show_temp_check.toggled.connect(func(_enabled: bool) -> void:
		_emit_debug_settings()
	)
	smell_layer_option.item_selected.connect(func(_idx: int) -> void:
		_emit_debug_settings()
	)
	set_spawn_mode("none")
	clear_inspector()
	set_status("Select mode active")
	_emit_debug_settings()

func _setup_debug_options() -> void:
	smell_layer_option.clear()
	for i in range(SMELL_LAYER_OPTIONS.size()):
		var row: Dictionary = SMELL_LAYER_OPTIONS[i]
		smell_layer_option.add_item(String(row.get("label", "Layer")), i)
	smell_layer_option.select(0)

func _emit_debug_settings() -> void:
	emit_signal("debug_settings_changed", {
		"show_smell": show_smell_check.button_pressed,
		"show_wind": show_wind_check.button_pressed,
		"show_temperature": show_temp_check.button_pressed,
		"smell_layer": _selected_smell_layer_id(),
	})

func _selected_smell_layer_id() -> String:
	var idx := clampi(smell_layer_option.selected, 0, maxi(0, SMELL_LAYER_OPTIONS.size() - 1))
	var row: Dictionary = SMELL_LAYER_OPTIONS[idx]
	return String(row.get("id", "all"))

func set_spawn_mode(mode: String) -> void:
	select_button.button_pressed = mode == "none"
	spawn_plant_button.button_pressed = mode == "plant"
	spawn_rabbit_button.button_pressed = mode == "rabbit"

func set_status(text: String) -> void:
	status_label.text = text

func set_metrics(text: String) -> void:
	metrics_label.text = text

func clear_inspector() -> void:
	inspector_title_label.text = "Inspector"
	inspector_text_label.text = "Click an actor to view details."

func show_inspector(payload: Dictionary) -> void:
	inspector_title_label.text = String(payload.get("title", "Inspector"))
	var lines: PackedStringArray = PackedStringArray()
	for key in payload.keys():
		if key == "title":
			continue
		lines.append("%s: %s" % [String(key), _format_value(payload[key])])
	inspector_text_label.text = "\n".join(lines)

func _format_value(value: Variant) -> String:
	if value is Dictionary:
		var parts: PackedStringArray = PackedStringArray()
		for key in value.keys():
			parts.append("%s=%s" % [String(key), _format_value(value[key])])
		return "{" + ", ".join(parts) + "}"
	if value is Vector3:
		var vec: Vector3 = value
		return "(%.2f, %.2f, %.2f)" % [vec.x, vec.y, vec.z]
	if value is float:
		return "%.3f" % float(value)
	return str(value)
