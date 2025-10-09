extends Node
class_name LocalAgentsAgentManager

signal agent_ready(agent)
signal configs_updated()

const CONFIG_LIST_PATH := "res://addons/local_agents/configuration/parameters/ConfigList.tres"
const DEFAULT_INFERENCE_PARAMS_PATH := "res://addons/local_agents/configuration/parameters/InferenceParams.tres"

var config_list: LocalAgentsConfigList
var agent: LocalAgentsAgent

func _ready() -> void:
    _ensure_config_list()
    if config_list.autoload_last_good_model_config and config_list.last_good_model_config:
        apply_model_config(config_list.last_good_model_config)
    if config_list.autoload_last_good_inference_config and config_list.last_good_inference_config:
        apply_inference_config(config_list.last_good_inference_config)
    if agent:
        emit_signal("agent_ready", agent)

func _ensure_agent() -> void:
    if agent:
        return
    agent = LocalAgentsAgent.new()
    agent.name = "Agent"
    add_child(agent)
    emit_signal("agent_ready", agent)

func register_agent(agent_instance: LocalAgentsAgent) -> void:
    agent = agent_instance
    if config_list.current_model_config:
        agent.configure(config_list.current_model_config, null)
    if config_list.current_inference_config:
        agent.configure(null, config_list.current_inference_config)
    emit_signal("agent_ready", agent_instance)

func _ensure_config_list() -> void:
    if FileAccess.file_exists(CONFIG_LIST_PATH):
        config_list = ResourceLoader.load(CONFIG_LIST_PATH)
    if config_list == null:
        config_list = LocalAgentsConfigList.new()
        _save_config_list()
    if config_list.inference_configurations.is_empty():
        var default_inference: LocalAgentsInferenceParams = ResourceLoader.load(DEFAULT_INFERENCE_PARAMS_PATH)
        if default_inference:
            config_list.inference_configurations.append(default_inference.duplicate(true))
        else:
            var fallback := LocalAgentsInferenceParams.new()
            fallback.inference_config_name = "<default>"
            config_list.inference_configurations.append(fallback)
        if config_list.current_inference_config == null:
            config_list.current_inference_config = config_list.inference_configurations[0]
        if config_list.last_good_inference_config == null:
            config_list.last_good_inference_config = config_list.inference_configurations[0]
        _save_config_list()

func _save_config_list() -> void:
    var err := ResourceSaver.save(config_list, CONFIG_LIST_PATH)
    if err != OK:
        push_error("Failed to save config list: %s" % err)

func apply_model_config(params: LocalAgentsModelParams) -> void:
    _ensure_agent()
    config_list.current_model_config = params
    if params:
        agent.configure(params, null)
        config_list.last_good_model_config = params
        _save_config_list()
        emit_signal("configs_updated")

func apply_inference_config(params: LocalAgentsInferenceParams) -> void:
    _ensure_agent()
    config_list.current_inference_config = params
    if params:
        agent.configure(null, params)
        config_list.last_good_inference_config = params
        _save_config_list()
        emit_signal("configs_updated")

func add_model_config(params: LocalAgentsModelParams) -> void:
    config_list.model_configurations.append(params)
    _save_config_list()
    emit_signal("configs_updated")

func remove_model_config(index: int) -> void:
    if index >= 0 and index < config_list.model_configurations.size():
        config_list.model_configurations.remove_at(index)
        _save_config_list()
        emit_signal("configs_updated")

func add_inference_config(params: LocalAgentsInferenceParams) -> void:
    config_list.inference_configurations.append(params)
    _save_config_list()
    emit_signal("configs_updated")

func remove_inference_config(index: int) -> void:
    if index >= 0 and index < config_list.inference_configurations.size():
        config_list.inference_configurations.remove_at(index)
        _save_config_list()
        emit_signal("configs_updated")

func get_model_configs() -> Array:
    return config_list.model_configurations

func get_inference_configs() -> Array:
    return config_list.inference_configurations

func set_autoload_last_good_model(enabled: bool) -> void:
    config_list.autoload_last_good_model_config = enabled
    _save_config_list()

func set_autoload_last_good_inference(enabled: bool) -> void:
    config_list.autoload_last_good_inference_config = enabled
    _save_config_list()
