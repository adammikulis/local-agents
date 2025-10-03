@tool
extends Control
class_name LocalAgentsModelConfig

@onready var manager: LocalAgentsAgentManager = get_node_or_null("/root/AgentManager")
@onready var name_edit: LineEdit = %ConfigNameLineEdit
@onready var max_actions_slider: HSlider = %ChatContextSizeHSlider
@onready var max_actions_label: Label = %ChatContextSizeLabel
@onready var tick_interval_slider: HSlider = %ChatModelGpuLayerCountHSlider
@onready var tick_interval_label: Label = %ChatModelGpuLayerCountLabel
@onready var voice_edit: LineEdit = %VoiceLineEdit
@onready var speak_check: CheckBox = %SpeakResponsesCheckBox
@onready var db_path_label: Label = %ChatCurrentModelPathLabel
@onready var select_db_button: Button = %SelectChatPathButton
@onready var clear_db_button: Button = %ClearChatPathButton
@onready var select_db_dialog: FileDialog = %SelectChatPathFileDialog

var current_config: LocalAgentsModelParams
var _updating := false

func _ready() -> void:
    _init_defaults()
    _init_signals()
    _load_from_manager()

func _init_defaults() -> void:
    current_config = LocalAgentsModelParams.new()
    current_config.model_config_name = "<default>"
    current_config.max_actions_per_tick = 4
    current_config.tick_interval = 0.0
    current_config.voice = ""
    current_config.speak_responses = false
    current_config.db_path = ""
    _refresh_ui()

func _init_signals() -> void:
    name_edit.text_changed.connect(_on_name_changed)
    max_actions_slider.value_changed.connect(_on_max_actions_changed)
    tick_interval_slider.value_changed.connect(_on_tick_interval_changed)
    voice_edit.text_changed.connect(_on_voice_changed)
    speak_check.toggled.connect(_on_speak_toggled)
    select_db_button.pressed.connect(_on_select_db_pressed)
    clear_db_button.pressed.connect(_on_clear_db_pressed)
    select_db_dialog.file_selected.connect(_on_db_file_selected)

func _load_from_manager() -> void:
    if manager and manager.config_list.current_model_config:
        var cfg = manager.config_list.current_model_config
        current_config.model_config_name = cfg.model_config_name
        current_config.db_path = cfg.db_path
        current_config.voice = cfg.voice
        current_config.speak_responses = cfg.speak_responses
        current_config.tick_interval = cfg.tick_interval
        current_config.max_actions_per_tick = cfg.max_actions_per_tick
        current_config.tick_enabled = cfg.tick_enabled
        _refresh_ui()

func _refresh_ui() -> void:
    _updating = true
    name_edit.text = current_config.model_config_name
    voice_edit.text = current_config.voice
    db_path_label.text = current_config.db_path
    speak_check.button_pressed = current_config.speak_responses
    _set_max_actions_label(current_config.max_actions_per_tick)
    _set_tick_interval_label(current_config.tick_interval)
    _updating = false

func _on_name_changed(new_text: String) -> void:
    if _updating:
        return
    current_config.model_config_name = new_text
    _apply()

func _on_max_actions_changed(value: float) -> void:
    if _updating:
        return
    var actions := int(round(pow(2.0, value)))
    actions = clamp(actions, 1, 4096)
    current_config.max_actions_per_tick = actions
    _set_max_actions_label(actions)
    _apply()

func _set_max_actions_label(actions: int) -> void:
    max_actions_label.text = str(actions)
    var slider_value := log(max(actions, 1)) / log(2)
    var prev := _updating
    _updating = true
    max_actions_slider.value = slider_value
    _updating = prev

func _on_tick_interval_changed(value: float) -> void:
    if _updating:
        return
    var seconds := value * 0.05
    current_config.tick_interval = seconds
    _set_tick_interval_label(seconds)
    _apply()

func _set_tick_interval_label(seconds: float) -> void:
    tick_interval_label.text = String.num(seconds, 2) + "s"
    var slider_value := seconds / 0.05
    var prev := _updating
    _updating = true
    tick_interval_slider.value = slider_value
    _updating = prev

func _on_voice_changed(new_text: String) -> void:
    if _updating:
        return
    current_config.voice = new_text
    _apply()

func _on_speak_toggled(enabled: bool) -> void:
    if _updating:
        return
    current_config.speak_responses = enabled
    _apply()

func _on_select_db_pressed() -> void:
    select_db_dialog.popup()

func _on_clear_db_pressed() -> void:
    current_config.db_path = ""
    db_path_label.text = ""
    _apply()

func _on_db_file_selected(path: String) -> void:
    current_config.db_path = path
    db_path_label.text = path
    _apply()

func _apply() -> void:
    if manager:
        manager.apply_model_config(current_config)
