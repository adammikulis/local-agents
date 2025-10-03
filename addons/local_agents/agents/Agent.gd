extends Node
class_name LocalAgentsAgent

signal model_output_received(text)
signal message_emitted(role, content)
signal action_requested(action, params)

var agent_node: AgentNode
var history: Array = []
var inference_options: Dictionary = {}

@export var db_path: String = ""
@export var voice: String = ""
@export var tick_enabled: bool = false
@export var tick_interval: float = 0.0
@export var max_actions_per_tick: int = 4

func _ready() -> void:
    agent_node = AgentNode.new()
    add_child(agent_node)
    var runtime_path := "res://addons/local_agents/gdextensions/localagents/bin"
    if DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(runtime_path)):
        agent_node.runtime_directory = runtime_path
    var default_model := "res://addons/local_agents/models/qwen3-4b-instruct/qwen2.5-3b-instruct-q4_k_m.gguf"
    if FileAccess.file_exists(default_model):
        agent_node.default_model_path = default_model
    agent_node.tick_enabled = tick_enabled
    agent_node.tick_interval = tick_interval
    agent_node.max_actions_per_tick = max_actions_per_tick
    if db_path != "":
        agent_node.db_path = db_path
    if voice != "":
        agent_node.voice = voice
    agent_node.connect("message_emitted", Callable(self, "_on_agent_message"))
    agent_node.connect("action_requested", Callable(self, "_on_agent_action"))
    var manager: LocalAgentsAgentManager = get_node_or_null("/root/AgentManager")
    if manager:
        manager.register_agent(self)

func configure(model_params: LocalAgentsModelParams = null, inference_params: LocalAgentsInferenceParams = null) -> void:
    if model_params:
        db_path = model_params.db_path
        voice = model_params.voice
        tick_enabled = model_params.tick_enabled
        tick_interval = model_params.tick_interval
        max_actions_per_tick = model_params.max_actions_per_tick
        if agent_node:
            agent_node.db_path = db_path
            agent_node.voice = voice
            agent_node.tick_enabled = tick_enabled
            agent_node.tick_interval = tick_interval
            agent_node.max_actions_per_tick = max_actions_per_tick
    if inference_params:
        inference_options = {
            "temperature": inference_params.temperature,
            "max_tokens": inference_params.max_tokens,
            "top_p": inference_params.top_p,
            "backend": inference_params.backend,
        }
        for key in inference_params.extra_options.keys():
            inference_options[key] = inference_params.extra_options[key]

func submit_user_message(text: String) -> void:
    history.append({"role": "user", "content": text})

func think(prompt: String, extra_opts: Dictionary = {}) -> Dictionary:
    submit_user_message(prompt)
    var opts := inference_options.duplicate(true)
    for key in extra_opts.keys():
        opts[key] = extra_opts[key]
    var result: Dictionary = agent_node.think(prompt, opts)
    var text := result.get("text", "")
    if text != "":
        history.append({"role": "assistant", "content": text})
        emit_signal("model_output_received", text)
    return result

func say(text: String, opts: Dictionary = {}) -> bool:
    return agent_node.say(text, opts)

func listen(opts: Dictionary = {}) -> String:
    return agent_node.listen(opts)

func clear_history() -> void:
    history.clear()
    if agent_node:
        agent_node.clear_history()

func get_history() -> Array:
    if agent_node:
        return agent_node.get_history()
    return history.duplicate(true)

func enqueue_action(name: String, params: Dictionary = {}):
    if agent_node:
        agent_node.enqueue_action(name, params)

func _on_agent_message(role: String, content: String) -> void:
    emit_signal("message_emitted", role, content)

func _on_agent_action(action: String, params: Dictionary) -> void:
    emit_signal("action_requested", action, params)
