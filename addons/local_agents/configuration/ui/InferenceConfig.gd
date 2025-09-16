extends Control
class_name LocalAgentsInferenceConfig

@onready var manager: LocalAgentsAgentManager = get_node_or_null("/root/AgentManager")
@onready var add_button: Button = %AddInferenceConfigButton
@onready var delete_button: Button = %DeleteInferenceConfigButton
@onready var back_button: Button = %BackButton
@onready var autoload_checkbox: CheckBox = %AutoloadLastGoodConfigCheckBox
@onready var list: ItemList = %SavedInferenceConfigsItemList
@onready var name_edit: LineEdit = %NameLineEdit
@onready var max_tokens_slider: HSlider = %MaxTokensHSlider
@onready var max_tokens_edit: LineEdit = %MaxTokensLineEdit
@onready var temperature_slider: HSlider = %TemperatureHSlider
@onready var temperature_edit: LineEdit = %TemperatureLineEdit
@onready var output_json_checkbox: CheckBox = %OutputJsonCheckBox

var current_config: LocalAgentsInferenceParams

func _ready() -> void:
    if manager:
        manager.connect("configs_updated", Callable(self, "_refresh_list"))
    _init_defaults()
    _init_signals()
    _refresh_list()
    _apply_saved_config()

func _init_defaults() -> void:
    current_config = LocalAgentsInferenceParams.new()
    current_config.inference_config_name = "<default>"
    current_config.temperature = 0.75
    current_config.max_tokens = 512
    current_config.top_p = 1.0
    current_config.extra_options = {"output_json": false}
    name_edit.text = current_config.inference_config_name
    _set_max_tokens(current_config.max_tokens)
    _set_temperature(current_config.temperature)
    output_json_checkbox.button_pressed = current_config.extra_options.get("output_json", false)

func _init_signals() -> void:
    add_button.pressed.connect(_on_add_pressed)
    delete_button.pressed.connect(_on_delete_pressed)
    back_button.pressed.connect(_on_back_pressed)
    autoload_checkbox.toggled.connect(_on_autoload_toggled)
    list.item_selected.connect(_on_item_selected)
    name_edit.text_changed.connect(_on_name_changed)
    max_tokens_slider.value_changed.connect(_on_max_tokens_slider_changed)
    temperature_slider.value_changed.connect(_on_temperature_slider_changed)
    output_json_checkbox.toggled.connect(_on_output_json_toggled)

func _apply_saved_config() -> void:
    if not manager:
        return
    autoload_checkbox.button_pressed = manager.config_list.autoload_last_good_inference_config
    var cfg := manager.config_list.last_good_inference_config
    if cfg:
        _load_config(cfg)

func _refresh_list() -> void:
    if not manager:
        return
    list.clear()
    for cfg in manager.get_inference_configs():
        list.add_item(cfg.inference_config_name)

func _on_add_pressed() -> void:
    if not manager:
        return
    var cfg := LocalAgentsInferenceParams.new()
    cfg.inference_config_name = current_config.inference_config_name
    cfg.temperature = current_config.temperature
    cfg.max_tokens = current_config.max_tokens
    cfg.top_p = current_config.top_p
    cfg.backend = current_config.backend
    cfg.extra_options = {"output_json": output_json_checkbox.button_pressed}
    manager.add_inference_config(cfg)
    manager.apply_inference_config(cfg)
    _refresh_list()

func _on_delete_pressed() -> void:
    if not manager:
        return
    var selected := list.get_selected_items()
    if selected.size() == 0:
        return
    manager.remove_inference_config(selected[0])
    _refresh_list()

func _on_back_pressed() -> void:
    hide()

func _on_autoload_toggled(pressed: bool) -> void:
    if manager:
        manager.set_autoload_last_good_inference(pressed)

func _on_item_selected(index: int) -> void:
    if not manager:
        return
    if index < 0 or index >= manager.get_inference_configs().size():
        return
    var cfg: LocalAgentsInferenceParams = manager.get_inference_configs()[index]
    manager.apply_inference_config(cfg)
    _load_config(cfg)

func _on_name_changed(new_text: String) -> void:
    current_config.inference_config_name = new_text

func _on_max_tokens_slider_changed(value: float) -> void:
    var tokens := int(round(pow(2.0, value)))
    tokens = max(tokens, 1)
    current_config.max_tokens = tokens
    max_tokens_edit.text = str(tokens)

func _set_max_tokens(tokens: int) -> void:
    current_config.max_tokens = tokens
    max_tokens_edit.text = str(tokens)
    max_tokens_slider.value = log(tokens) / log(2)

func _on_temperature_slider_changed(value: float) -> void:
    current_config.temperature = float(value)
    temperature_edit.text = String.num(value, 2)

func _set_temperature(value: float) -> void:
    current_config.temperature = value
    temperature_slider.value = value
    temperature_edit.text = String.num(value, 2)

func _on_output_json_toggled(pressed: bool) -> void:
    current_config.extra_options["output_json"] = pressed

func _load_config(cfg: LocalAgentsInferenceParams) -> void:
    current_config = cfg
    name_edit.text = cfg.inference_config_name
    _set_max_tokens(cfg.max_tokens)
    _set_temperature(cfg.temperature)
    output_json_checkbox.button_pressed = cfg.extra_options.get("output_json", false)
