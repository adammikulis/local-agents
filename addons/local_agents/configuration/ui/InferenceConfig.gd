@tool
extends Control
class_name LocalAgentsInferenceConfig

@onready var manager: LocalAgentsAgentManager = get_node_or_null("/root/AgentManager")
@onready var add_button: Button = %AddInferenceConfigButton
@onready var delete_button: Button = %DeleteInferenceConfigButton
@onready var back_button: Button = %BackButton
@onready var autoload_checkbox: CheckBox = %AutoloadLastGoodConfigCheckBox
@onready var list: ItemList = %SavedInferenceConfigsItemList
@onready var name_edit: LineEdit = %NameLineEdit
@onready var backend_edit: LineEdit = %BackendLineEdit
@onready var max_tokens_slider: HSlider = %MaxTokensHSlider
@onready var max_tokens_spin: SpinBox = %MaxTokensSpinBox
@onready var temperature_slider: HSlider = %TemperatureHSlider
@onready var temperature_spin: SpinBox = %TemperatureSpinBox
@onready var top_p_spin: SpinBox = %TopPSpinBox
@onready var top_k_spin: SpinBox = %TopKSpinBox
@onready var min_p_spin: SpinBox = %MinPSpinBox
@onready var typical_spin: SpinBox = %TypicalSpinBox
@onready var repeat_penalty_spin: SpinBox = %RepeatPenaltySpinBox
@onready var repeat_last_n_spin: SpinBox = %RepeatLastNSpinBox
@onready var frequency_penalty_spin: SpinBox = %FrequencyPenaltySpinBox
@onready var presence_penalty_spin: SpinBox = %PresencePenaltySpinBox
@onready var seed_spin: SpinBox = %SeedSpinBox
@onready var random_seed_button: Button = %RandomSeedButton
@onready var mirostat_option: OptionButton = %MirostatOptionButton
@onready var mirostat_tau_spin: SpinBox = %MirostatTauSpinBox
@onready var mirostat_eta_spin: SpinBox = %MirostatEtaSpinBox
@onready var mirostat_m_spin: SpinBox = %MirostatMSpinBox
@onready var output_json_checkbox: CheckBox = %OutputJsonCheckBox

var current_config: LocalAgentsInferenceParams
var _updating_ui := false
var _rng := RandomNumberGenerator.new()

func _ready() -> void:
    _rng.randomize()
    if manager:
        manager.configs_updated.connect(_refresh_list)
    _init_defaults()
    _init_signals()
    _refresh_list()
    _apply_saved_config()

func _init_defaults() -> void:
    current_config = LocalAgentsInferenceParams.new()
    current_config.inference_config_name = "<default>"
    current_config.temperature = 0.8
    current_config.max_tokens = 512
    current_config.top_p = 0.95
    current_config.min_p = 0.05
    current_config.repeat_penalty = 1.1
    current_config.repeat_last_n = 64
    current_config.frequency_penalty = 0.0
    current_config.presence_penalty = 0.0
    current_config.seed = -1
    current_config.mirostat_mode = 0
    current_config.mirostat_tau = 5.0
    current_config.mirostat_eta = 0.1
    current_config.mirostat_m = 100
    current_config.output_json = false
    _apply_config_to_ui(current_config)

func _init_signals() -> void:
    add_button.pressed.connect(_on_add_pressed)
    delete_button.pressed.connect(_on_delete_pressed)
    back_button.pressed.connect(_on_back_pressed)
    autoload_checkbox.toggled.connect(_on_autoload_toggled)
    list.item_selected.connect(_on_item_selected)
    name_edit.text_changed.connect(func(new_text: String):
        current_config.inference_config_name = new_text
        if not _updating_ui:
            _publish_current_config()
    )
    backend_edit.text_changed.connect(func(new_text: String):
        current_config.backend = new_text.strip_edges()
        if not _updating_ui:
            _publish_current_config()
    )

    max_tokens_slider.value_changed.connect(_on_max_tokens_slider_changed)
    max_tokens_spin.value_changed.connect(_on_max_tokens_spin_changed)
    temperature_slider.value_changed.connect(_on_temperature_slider_changed)
    temperature_spin.value_changed.connect(_on_temperature_spin_changed)

    _bind_spin(top_p_spin, "top_p")
    _bind_spin(top_k_spin, "top_k", true)
    _bind_spin(min_p_spin, "min_p")
    _bind_spin(typical_spin, "typical_p")
    _bind_spin(repeat_penalty_spin, "repeat_penalty")
    _bind_spin(repeat_last_n_spin, "repeat_last_n", true)
    _bind_spin(frequency_penalty_spin, "frequency_penalty")
    _bind_spin(presence_penalty_spin, "presence_penalty")
    _bind_spin(mirostat_tau_spin, "mirostat_tau")
    _bind_spin(mirostat_eta_spin, "mirostat_eta")
    _bind_spin(mirostat_m_spin, "mirostat_m", true)

    _bind_spin(seed_spin, "seed", true, true)
    random_seed_button.pressed.connect(_on_random_seed_pressed)

    mirostat_option.item_selected.connect(_on_mirostat_mode_selected)
    output_json_checkbox.toggled.connect(func(pressed: bool):
        current_config.output_json = pressed
        if not _updating_ui:
            _publish_current_config()
    )

func _apply_saved_config() -> void:
    if not manager:
        return
    autoload_checkbox.button_pressed = manager.config_list.autoload_last_good_inference_config
    var cfg: LocalAgentsInferenceParams = manager.config_list.last_good_inference_config
    if cfg:
        _load_config(cfg)

func _refresh_list() -> void:
    if not manager:
        return
    var selected_name := current_config.inference_config_name
    list.clear()
    var configs := manager.get_inference_configs()
    for cfg in configs:
        list.add_item(cfg.inference_config_name)
    for idx in range(configs.size()):
        if configs[idx] == current_config:
            list.select(idx)
            break
        if configs[idx].inference_config_name == selected_name:
            list.select(idx)

func _on_add_pressed() -> void:
    if not manager:
        return
    var cfg: LocalAgentsInferenceParams = current_config.duplicate(true)
    manager.add_inference_config(cfg)
    manager.apply_inference_config(cfg)
    _refresh_list()
    _load_config(cfg)

func _on_delete_pressed() -> void:
    if not manager:
        return
    var selected := list.get_selected_items()
    if selected.is_empty():
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
    var configs := manager.get_inference_configs()
    if index < 0 or index >= configs.size():
        return
    var cfg: LocalAgentsInferenceParams = configs[index]
    manager.apply_inference_config(cfg)
    _load_config(cfg)

func _on_max_tokens_slider_changed(value: float) -> void:
    if _updating_ui:
        return
    var tokens := int(round(pow(2.0, value)))
    tokens = max(tokens, 1)
    _apply_max_tokens(tokens)

func _on_max_tokens_spin_changed(value: float) -> void:
    if _updating_ui:
        return
    _apply_max_tokens(int(round(value)))

func _on_temperature_slider_changed(value: float) -> void:
    if _updating_ui:
        return
    _apply_temperature(value)

func _on_temperature_spin_changed(value: float) -> void:
    if _updating_ui:
        return
    _apply_temperature(value)

func _on_random_seed_pressed() -> void:
    var random_value := _rng.randi_range(0, 2147483647)
    _set_seed(random_value)

func _on_mirostat_mode_selected(index: int) -> void:
    if _updating_ui:
        return
    current_config.mirostat_mode = mirostat_option.get_item_id(index)
    _publish_current_config()

func _load_config(cfg: LocalAgentsInferenceParams) -> void:
    current_config = cfg
    _apply_config_to_ui(cfg)

func _apply_config_to_ui(cfg: LocalAgentsInferenceParams) -> void:
    _updating_ui = true
    name_edit.text = cfg.inference_config_name
    backend_edit.text = cfg.backend
    output_json_checkbox.button_pressed = cfg.output_json
    max_tokens_spin.value = cfg.max_tokens
    max_tokens_slider.value = _tokens_to_slider(cfg.max_tokens)
    temperature_spin.value = cfg.temperature
    temperature_slider.value = cfg.temperature
    top_p_spin.value = cfg.top_p
    top_k_spin.value = cfg.top_k
    min_p_spin.value = cfg.min_p
    typical_spin.value = cfg.typical_p
    repeat_penalty_spin.value = cfg.repeat_penalty
    repeat_last_n_spin.value = cfg.repeat_last_n
    frequency_penalty_spin.value = cfg.frequency_penalty
    presence_penalty_spin.value = cfg.presence_penalty
    seed_spin.value = cfg.seed
    mirostat_tau_spin.value = cfg.mirostat_tau
    mirostat_eta_spin.value = cfg.mirostat_eta
    mirostat_m_spin.value = cfg.mirostat_m
    var mode_index := _find_mirostat_index(cfg.mirostat_mode)
    if mode_index != -1:
        mirostat_option.select(mode_index)
    _updating_ui = false

func _apply_max_tokens(tokens: int) -> void:
    tokens = clamp(tokens, 1, int(max_tokens_spin.max_value))
    current_config.max_tokens = tokens
    _updating_ui = true
    max_tokens_spin.value = tokens
    max_tokens_slider.value = _tokens_to_slider(tokens)
    _updating_ui = false
    _publish_current_config()

func _apply_temperature(value: float) -> void:
    value = clamp(value, temperature_spin.min_value, temperature_spin.max_value)
    current_config.temperature = value
    _updating_ui = true
    temperature_spin.value = value
    temperature_slider.value = value
    _updating_ui = false
    _publish_current_config()

func _set_seed(value: int) -> void:
    if value < 0:
        value = -1
    current_config.seed = value
    _updating_ui = true
    seed_spin.value = value
    _updating_ui = false
    _publish_current_config()

func _bind_spin(spin: SpinBox, property_name: String, use_int: bool = false, allow_negative_one: bool = false) -> void:
    spin.value_changed.connect(func(value: float):
        if _updating_ui:
            return
        var final_value = value
        if use_int:
            final_value = int(round(value))
        if allow_negative_one and final_value < 0:
            final_value = -1
        if use_int or allow_negative_one:
            _updating_ui = true
            spin.value = final_value
            _updating_ui = false
        current_config.set(property_name, final_value)
        _publish_current_config()
    )

func _tokens_to_slider(tokens: int) -> float:
    if tokens <= 1:
        return max_tokens_slider.min_value
    var exponent := log(float(tokens)) / log(2.0)
    return clamp(exponent, max_tokens_slider.min_value, max_tokens_slider.max_value)

func _publish_current_config() -> void:
    if manager and manager.config_list.current_inference_config == current_config:
        manager.apply_inference_config(current_config)

func _find_mirostat_index(mode_id: int) -> int:
    for idx in range(mirostat_option.item_count):
        if mirostat_option.get_item_id(idx) == mode_id:
            return idx
    return -1
