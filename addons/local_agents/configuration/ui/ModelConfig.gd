@tool
extends Control
class_name LAModelConfig

# Editor/in-game panel for ONE LocalAgentModelProfile: which .gguf to load, how big a context to
# give it, and how many layers to push onto the GPU. It edits the same Resource a developer would
# fill in from the inspector, so the two paths cannot drift.
#
# The scene also carries voice / "speak responses" controls from an older layout. Those are agent
# behaviour, not model loading (LocalAgent exports them directly), so they are hidden here rather
# than left on screen doing nothing.

const ModelProfile: GDScript = preload("res://addons/local_agents/configuration/parameters/ModelProfile.gd")

# Context slider is exponential: tokens = CONTEXT_BASE << slider_value.
const CONTEXT_BASE: int = 256
const CONTEXT_MIN: int = 256
const CONTEXT_MAX: int = 1048576

@onready var manager: LocalAgentManager = get_node_or_null("/root/AgentManager")
@onready var name_edit: LineEdit = %ConfigNameLineEdit
@onready var context_slider: HSlider = %ChatContextSizeHSlider
@onready var context_label: Label = %ChatContextSizeLabel
@onready var gpu_layers_slider: HSlider = %ChatModelGpuLayerCountHSlider
@onready var gpu_layers_label: Label = %ChatModelGpuLayerCountLabel
@onready var voice_edit: LineEdit = %VoiceLineEdit
@onready var speak_check: CheckBox = %SpeakResponsesCheckBox
@onready var model_path_label: Label = %ChatCurrentModelPathLabel
@onready var select_model_button: Button = %SelectChatPathButton
@onready var clear_model_button: Button = %ClearChatPathButton
@onready var select_model_dialog: FileDialog = %SelectChatPathFileDialog

var current_config: LocalAgentModelProfile
var _updating: bool = false

func _ready() -> void:
    _init_defaults()
    _init_signals()
    _hide_agent_only_controls()
    _load_from_manager()

func _init_defaults() -> void:
    current_config = ModelProfile.new()
    current_config.profile_name = "<default>"
    current_config.model_path = ""
    current_config.context_size = 4096
    current_config.gpu_layers = 0
    _refresh_ui()

func _init_signals() -> void:
    name_edit.text_changed.connect(_on_name_changed)
    context_slider.value_changed.connect(_on_context_slider_changed)
    gpu_layers_slider.value_changed.connect(_on_gpu_layers_changed)
    select_model_button.pressed.connect(_on_select_model_pressed)
    clear_model_button.pressed.connect(_on_clear_model_pressed)
    select_model_dialog.file_selected.connect(_on_model_file_selected)
    select_model_dialog.clear_filters()
    select_model_dialog.add_filter("*.gguf", "GGUF model")

# Voice and speech belong to the LocalAgent node, not to a model profile. The scene still carries
# their controls; hide the rows so the panel only shows knobs that actually do something.
func _hide_agent_only_controls() -> void:
    var voice_row: Control = voice_edit.get_parent() as Control
    if voice_row != null:
        voice_row.visible = false
    var speech_row: Control = speak_check.get_parent() as Control
    if speech_row != null:
        speech_row.visible = false

func _load_from_manager() -> void:
    if manager == null or manager.config_list == null:
        return
    var cfg: LocalAgentModelProfile = manager.config_list.current_model_config as LocalAgentModelProfile
    if cfg == null:
        return
    current_config = cfg
    _refresh_ui()

func _refresh_ui() -> void:
    _updating = true
    name_edit.text = current_config.profile_name
    model_path_label.text = current_config.model_path
    _set_context_label(current_config.context_size)
    _set_gpu_layers_label(current_config.gpu_layers)
    _updating = false

func _on_name_changed(new_text: String) -> void:
    if _updating:
        return
    current_config.profile_name = new_text
    _apply()

func _on_context_slider_changed(value: float) -> void:
    if _updating:
        return
    var tokens: int = CONTEXT_BASE << int(round(value))
    tokens = clampi(tokens, CONTEXT_MIN, CONTEXT_MAX)
    current_config.context_size = tokens
    _set_context_label(tokens)
    _apply()

func _set_context_label(tokens: int) -> void:
    context_label.text = "%d tok" % tokens
    var steps: float = log(float(maxi(tokens, CONTEXT_MIN)) / float(CONTEXT_BASE)) / log(2.0)
    var prev: bool = _updating
    _updating = true
    context_slider.value = clampf(steps, context_slider.min_value, context_slider.max_value)
    _updating = prev

func _on_gpu_layers_changed(value: float) -> void:
    if _updating:
        return
    var layers: int = maxi(0, int(round(value)))
    current_config.gpu_layers = layers
    _set_gpu_layers_label(layers)
    _apply()

func _set_gpu_layers_label(layers: int) -> void:
    gpu_layers_label.text = "CPU only" if layers <= 0 else str(layers)
    var prev: bool = _updating
    _updating = true
    gpu_layers_slider.value = clampf(float(layers), gpu_layers_slider.min_value, gpu_layers_slider.max_value)
    _updating = prev

func _on_select_model_pressed() -> void:
    select_model_dialog.popup()

func _on_clear_model_pressed() -> void:
    current_config.model_path = ""
    model_path_label.text = ""
    _apply()

func _on_model_file_selected(path: String) -> void:
    current_config.model_path = path
    model_path_label.text = path
    _apply()

func _apply() -> void:
    if manager != null:
        manager.apply_model_config(current_config)
