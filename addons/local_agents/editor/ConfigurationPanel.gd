@tool
extends Control
class_name LocalAgentsConfigurationPanel

@onready var _tabs: TabContainer = %ConfigTabs
@onready var _model_config: LocalAgentsModelConfig = %ModelConfig
@onready var _inference_config: LocalAgentsInferenceConfig = %InferenceConfig
@onready var _flow_config: LocalAgentsFlowTraversalConfig = %FlowTraversalConfig

var _manager: LocalAgentsAgentManager

func _ready() -> void:
    _manager = get_node_or_null("/root/AgentManager")
    if _manager:
        _manager.configs_updated.connect(refresh_configs)

func focus_model() -> void:
    if not _tabs:
        return
    var target := _model_config
    if target:
        var container := target.get_parent()
        if container and container is Control:
            var idx := _tabs.get_tab_idx_from_control(container)
            if idx != -1:
                _tabs.current_tab = idx

func focus_inference() -> void:
    if not _tabs:
        return
    var target := _inference_config
    if target:
        var container := target.get_parent()
        if container and container is Control:
            var idx := _tabs.get_tab_idx_from_control(container)
            if idx != -1:
                _tabs.current_tab = idx

func refresh_configs() -> void:
    if _model_config:
        _model_config._load_from_manager()
    if _inference_config:
        _inference_config._apply_saved_config()
    if _flow_config:
        _flow_config.reload_profile()
