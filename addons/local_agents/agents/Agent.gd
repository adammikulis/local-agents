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
    var runtime_dir := _resolve_runtime_directory()
    if runtime_dir != "":
        agent_node.runtime_directory = runtime_dir
    var default_model := "res://addons/local_agents/models/qwen3-4b-instruct/qwen3-4b-instruct-2507-q4_k_m.gguf"
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
        inference_options = inference_params.to_options()

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

func set_history(messages: Array) -> void:
    clear_history()
    for entry_variant in messages:
        var entry: Dictionary = {}
        if entry_variant is Dictionary:
            entry = entry_variant
        else:
            continue
        var role_value := entry.get("role", "")
        var content_value := entry.get("content", "")
        var role := role_value as String if role_value is String else str(role_value)
        var content := content_value as String if content_value is String else str(content_value)
        if role.is_empty() or content.strip_edges().is_empty():
            continue
        history.append({
            "role": role,
            "content": content,
        })
        if agent_node:
            agent_node.add_message(role, content)

func enqueue_action(name: String, params: Dictionary = {}):
    if agent_node:
        agent_node.enqueue_action(name, params)

func _resolve_runtime_directory() -> String:
    var base := "res://addons/local_agents/gdextensions/localagents/bin/runtimes"
    var subdir := _detect_runtime_subdir()
    if subdir != "":
        var candidate := "%s/%s" % [base, subdir]
        if DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(candidate)):
            return candidate
    if DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(base)):
        return base
    return ""

func _detect_runtime_subdir() -> String:
    var os_name := OS.get_name()
    if os_name == "macOS":
        if OS.has_feature("arm64"):
            return "macos_arm64"
        return "macos_x86_64"
    if os_name == "Windows":
        return "windows_x86_64"
    if os_name == "Linux":
        if OS.has_feature("aarch64") or OS.has_feature("arm64"):
            return "linux_aarch64"
        if OS.has_feature("x86_64"):
            return "linux_x86_64"
        if OS.has_feature("armv7"):
            return "linux_armv7l"
    if os_name == "Android":
        return "android_arm64"
    return ""

func _on_agent_message(role: String, content: String) -> void:
    emit_signal("message_emitted", role, content)

func _on_agent_action(action: String, params: Dictionary) -> void:
    emit_signal("action_requested", action, params)
