extends Node
class_name LocalAgentManager

signal agent_ready(agent)
signal configs_updated()

# res:// is not writable in an exported build, so the shipped .tres is a seed. Load user:// when
# present, else the res:// seed; always save to user:// (copy-on-first-write).
const CONFIG_LIST_SEED_PATH: String = "res://addons/local_agents/configuration/parameters/ConfigList.tres"
const USER_CONFIG_LIST_PATH: String = "user://local_agents/config/ConfigList.tres"
const DEFAULT_INFERENCE_PARAMS_PATH: String = "res://addons/local_agents/configuration/parameters/InferenceParams.tres"
const ExtensionLoader: GDScript = preload("res://addons/local_agents/runtime/LocalAgentExtensionLoader.gd")
const AgentScript: GDScript = preload("res://addons/local_agents/agents/Agent.gd")
const ConfigListScript: GDScript = preload("res://addons/local_agents/configuration/parameters/ConfigList.gd")
const InferenceParamsScript: GDScript = preload("res://addons/local_agents/configuration/parameters/InferenceParams.gd")

var config_list: Resource
var agent: Node

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
    if not ExtensionLoader.ensure_initialized():
        push_warning("Local Agents extension unavailable; AgentManager will retry when activated")
        return
    agent = AgentScript.new()
    agent.name = "Agent"
    add_child(agent)
    emit_signal("agent_ready", agent)

func register_agent(agent_instance: Node) -> void:
    _ensure_config_list()
    agent = agent_instance
    if config_list.current_model_config:
        _apply_model_profile(config_list.current_model_config as LocalAgentModelProfile)
    if config_list.current_inference_config:
        agent.configure(null, config_list.current_inference_config)
    emit_signal("agent_ready", agent_instance)

func _ensure_config_list() -> void:
    var seeded_from_default: bool = false
    var had_user_file: bool = false
    if FileAccess.file_exists(USER_CONFIG_LIST_PATH):
        had_user_file = true
        config_list = ResourceLoader.load(USER_CONFIG_LIST_PATH)
    elif FileAccess.file_exists(CONFIG_LIST_SEED_PATH):
        # First run in this user profile: seed from the read-only shipped default, then persist to user://.
        config_list = ResourceLoader.load(CONFIG_LIST_SEED_PATH)
        seeded_from_default = true
    if config_list == null:
        if had_user_file:
            var salvage_path: String = "%s.unreadable" % USER_CONFIG_LIST_PATH
            if DirAccess.copy_absolute(
                    ProjectSettings.globalize_path(USER_CONFIG_LIST_PATH),
                    ProjectSettings.globalize_path(salvage_path)) == OK:
                push_warning("Local Agents: could not read %s, so it was reset. The previous file was kept at %s." % [USER_CONFIG_LIST_PATH, salvage_path])
            else:
                push_warning("Local Agents: could not read %s and it has been reset. Saved model and inference configs were lost." % USER_CONFIG_LIST_PATH)
        config_list = ConfigListScript.new()
        _save_config_list()
    elif seeded_from_default:
        _save_config_list()
    if config_list.inference_configurations.is_empty():
        var default_inference = ResourceLoader.load(DEFAULT_INFERENCE_PARAMS_PATH)
        if default_inference:
            config_list.inference_configurations.append(default_inference.duplicate(true))
        else:
            var fallback = InferenceParamsScript.new()
            fallback.inference_config_name = "<default>"
            config_list.inference_configurations.append(fallback)
        if config_list.current_inference_config == null:
            config_list.current_inference_config = config_list.inference_configurations[0]
        if config_list.last_good_inference_config == null:
            config_list.last_good_inference_config = config_list.inference_configurations[0]
        _save_config_list()

func _save_config_list() -> void:
    var save_dir: String = USER_CONFIG_LIST_PATH.get_base_dir()
    if not DirAccess.dir_exists_absolute(save_dir):
        DirAccess.make_dir_recursive_absolute(save_dir)
    var err: int = ResourceSaver.save(config_list, USER_CONFIG_LIST_PATH)
    if err != OK:
        push_error("Failed to save config list: %s" % err)

## Makes `params` the model profile every agent loads from now on, and persists it.
func apply_model_config(params: LocalAgentModelProfile) -> void:
    _ensure_config_list()
    _ensure_agent()
    config_list.current_model_config = params
    if params:
        if agent:
            _apply_model_profile(params)
        else:
            push_warning("Agent unavailable; model config saved and will apply after runtime activation")
        config_list.last_good_model_config = params
        _save_config_list()
        emit_signal("configs_updated")

func _apply_model_profile(params: LocalAgentModelProfile) -> void:
    if agent == null or params == null:
        return
    agent.set("load_options", params.to_options())

func apply_inference_config(params) -> void:
    _ensure_config_list()
    _ensure_agent()
    config_list.current_inference_config = params
    if params:
        if agent:
            agent.configure(null, params)
        else:
            push_warning("Agent unavailable; inference config saved and will apply after runtime activation")
        config_list.last_good_inference_config = params
        _save_config_list()
        emit_signal("configs_updated")

## Adds `params` to the saved list of model profiles without making it the active one.
func add_model_config(params: LocalAgentModelProfile) -> void:
    config_list.model_configurations.append(params)
    _save_config_list()
    emit_signal("configs_updated")

func remove_model_config(index: int) -> void:
    if index >= 0 and index < config_list.model_configurations.size():
        config_list.model_configurations.remove_at(index)
        _save_config_list()
        emit_signal("configs_updated")

func add_inference_config(params) -> void:
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
