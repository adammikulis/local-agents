@tool
@icon("res://addons/local_agents/icons/local_agent.svg")
extends Node
class_name LocalAgent


signal model_output_received(text)
signal message_emitted(role, content)
signal action_requested(action, params)
signal think_completed(result)

var agent_node: Object
var history: Array = []
## Sampling settings (temperature, penalties, backend). configure() replaces this wholesale when it
## is handed an inference preset, so nothing else may store state here.
var inference_options: Dictionary = {}
var load_options: Dictionary = {}
const ExtensionLoader: GDScript = preload("res://addons/local_agents/runtime/LocalAgentExtensionLoader.gd")
const RuntimePaths: GDScript = preload("res://addons/local_agents/runtime/RuntimePaths.gd")
const AgentStatus: GDScript = preload("res://addons/local_agents/runtime/AgentStatus.gd")
const AgentWarnings: GDScript = preload("res://addons/local_agents/agents/AgentWarnings.gd")
const ModelSettingsStore: GDScript = preload("res://addons/local_agents/runtime/ModelSettingsStore.gd")
const AgentHistory: GDScript = preload("res://addons/local_agents/agents/AgentHistory.gd")
const AgentJobs: GDScript = preload("res://addons/local_agents/agents/AgentJobs.gd")
const AgentServer: GDScript = preload("res://addons/local_agents/agents/AgentServer.gd")
const AgentSpeech: GDScript = preload("res://addons/local_agents/agents/AgentSpeech.gd")
const AgentBackstory: GDScript = preload("res://addons/local_agents/agents/AgentBackstory.gd")

@export_group("Model")

## The GGUF weights this agent loads. Leave empty to fall back to the project default in
## Project Settings > local_agents/model/default_path (and the search paths under it).
@export_global_file("*.gguf") var model_path: String = "":
    set(value):
        model_path = value
        _apply_model_path()
        _refresh_warnings()

## Standing instruction put in front of every conversation, e.g. "You are a terse dockside guide."
## Empty uses whatever the Model Profile or the runtime default supplies.
@export_multiline var system_prompt: String = "":
    set(value):
        system_prompt = value
        _refresh_warnings()

@export var model_profile: LocalAgentModelProfile = null:
    set(value):
        model_profile = value
        _apply_model_path()
        _refresh_warnings()

## How the model generates: temperature, penalties, and which backend runs the request. Empty uses
## the project's default preset.
@export var inference: LocalAgentInferenceParams = null:
    set(value):
        inference = value
        _refresh_warnings()

## Load the weights when the scene starts instead of on the first think(). Costs a visible stall at
## load time and buys a first reply with no wait. Ignored for the llama-server backend, which loads
## the model in its own process.
@export var preload_model: bool = false

## Let the model the player picked in the in-game model manager
## (user://local_agents/model_settings.cfg) override Model Path, Model Profile and Inference above.
@export var use_player_settings: bool = false

@export_group("Speech")

## Piper voice id under addons/local_agents/voices. Give a folder name or an .onnx basename,
## e.g. "en_US-amy". Empty means this agent never speaks.
@export_placeholder("en_US-amy") var voice: String = "":
    set(value):
        voice = value
        if agent_node != null and is_instance_valid(agent_node):
            agent_node.voice = voice
        _refresh_warnings()

## Say every reply out loud through Voice, as well as emitting it as text.
@export var speak_responses: bool = false:
    set(value):
        speak_responses = value
        _refresh_warnings()

@export_group("Autonomy")

## Let the agent act on its own, so the native runtime ticks it and it may emit action_requested
## without anyone calling think(). Off means it only ever responds when asked.
@export var tick_enabled: bool = false:
    set(value):
        tick_enabled = value
        if agent_node != null and is_instance_valid(agent_node):
            agent_node.tick_enabled = tick_enabled
        _refresh_warnings()

## Seconds of game time between autonomous ticks. 0 disables ticking. The native runtime returns
## early on a non-positive interval (AgentNode.cpp:56), so an agent set to 0 never acts at all.
@export_range(0.0, 60.0, 0.05, "or_greater", "suffix:s") var tick_interval: float = 1.0:
    set(value):
        tick_interval = value
        if agent_node != null and is_instance_valid(agent_node):
            agent_node.tick_interval = tick_interval
        _refresh_warnings()

@export_group("Memory")

## Knowledge graph this agent writes its conversation into: every message it is given and every reply
## it produces becomes a node, chained to the one before it by a "then" edge. Empty keeps no graph.
## Two agents handed the same graph resource write into one shared record.
@export var memory_graph: LocalAgentGraph = null

@export var backstory: LocalAgentBackstoryGraphService = null:
    set(value):
        backstory = value
        _sync_backstory()

@export var npc_id: String = "":
    set(value):
        npc_id = value
        _sync_backstory()

## Display name written into the store the first time this agent is seen. Cosmetic: it is what a
## debugger or a relationship query shows instead of a bare id.
@export var npc_display_name: String = ""

## Put the memories most relevant to each prompt in front of the model before it answers. Off by
## default because it costs tokens on every turn and only helps once there is something remembered.
@export var recall_memories: bool = false

## How many memories to recall. Kept small deliberately: this text is prepended to every request, and a
## long wall of half-relevant memory makes replies worse, not better.
@export_range(1, 32, 1) var recall_limit: int = 6

@export_global_file("*.db", "*.sqlite", "*.sqlite3") var db_path: String = "":
    set(value):
        db_path = value
        if agent_node != null and is_instance_valid(agent_node) and db_path != "":
            agent_node.db_path = db_path

# The four helpers this node delegates to. Plain RefCounted, constructed with the node (so a setter
# that fires during scene load already has one to talk to) and dropped with it.
var _history: AgentHistory = AgentHistory.new()
var _jobs: AgentJobs = AgentJobs.new()
var _server: AgentServer = AgentServer.new()
var _speech: AgentSpeech = AgentSpeech.new()
var _backstory: AgentBackstory = AgentBackstory.new()
# The player's saved in-game model settings, read once on first use. Null until Use Player Settings
# is on and a settings file exists.
var _player_store: LocalAgentModelSettingsStore = null
# model_path of the profile configure() was last handed. Sits below this node's own Model Path in the
# resolution order and above the project-wide default.
var _configured_model_path: String = ""

## Keep the backstory module pointed at whatever the inspector currently says. Called from the setters
## rather than only from _ready() so changing the slot or the id on a live agent takes effect.
func _sync_backstory() -> void:
    if _backstory == null:
        return
    _backstory.attach(backstory, npc_id, npc_display_name)


## Memories worth putting in front of `prompt`, as a system message, or "" when there are none. Public
## because a caller driving the native node directly still wants the recall.
func recall_context(prompt: String) -> String:
    if not recall_memories:
        return ""
    return _backstory.recall(prompt, recall_limit)


func _ready() -> void:
    if Engine.is_editor_hint():
        return   # @tool: an agent in an open scene must not boot the runtime inside the editor
    if not _ensure_agent_node():
        push_warning("Local Agents extension unavailable; agent node inactive")
        return
    _speech.attach(self)
    # Also here, not only in the setters: during scene load the exports arrive one at a time, so the
    # slot can be assigned before the id and display name are.
    _sync_backstory()
    if not agent_node.is_connected("message_emitted", Callable(self, "_on_agent_message")):
        agent_node.connect("message_emitted", Callable(self, "_on_agent_message"))
    if not agent_node.is_connected("action_requested", Callable(self, "_on_agent_action")):
        agent_node.connect("action_requested", Callable(self, "_on_agent_action"))
    if is_inside_tree():
        _register_with_manager()
    else:
        call_deferred("_register_with_manager")
    # A llama-server keeps the weights in its own process, so an in-process preload would only load
    # them a second time for nothing.
    if preload_model and not AgentServer.is_server_backend(_merged_options({})):
        ensure_model_loaded()

func _register_with_manager() -> void:
    var manager = get_node_or_null("/root/AgentManager")
    if manager:
        manager.register_agent(self)

func configure(model_profile_config: LocalAgentModelProfile = null, inference_params: LocalAgentInferenceParams = null) -> void:
    _ensure_agent_node()
    if model_profile_config != null:
        load_options = model_profile_config.to_options()
        _configured_model_path = model_profile_config.model_path.strip_edges()
        _apply_model_path()
    if inference_params != null:
        inference_options = inference_params.to_options()

func is_runtime_ready() -> bool:
    var state: Dictionary = AgentStatus.check()
    return bool(state["extension_ok"]) and bool(state["autoload_ok"])

## True when this agent has weights to use and the runtime currently holds a model in memory.
func is_model_ready() -> bool:
    return resolve_model_path() != "" and bool(AgentStatus.check()["model_loaded"])

func ensure_model_loaded() -> bool:
    var explicit: String = _per_agent_model_path()
    if explicit == "":
        return AgentStatus.ensure_model_loaded()
    return _load_runtime_model(explicit, _merged_options({}))

## One or two lines safe to drop straight into a Label: what state Local Agents is in, and the single
## next thing to do about it when something is blocking.
func status_text() -> String:
    var state: Dictionary = AgentStatus.check()
    var headline: String = String(state["headline"])
    var next_step: String = String(state["next_step"])
    return headline if next_step == "" else "%s\n%s" % [headline, next_step]

## The GGUF this agent will actually use: its own overrides first (see _per_agent_model_path), then
## the project-wide default. "" when no model is installed anywhere.
func resolve_model_path() -> String:
    var explicit: String = _per_agent_model_path()
    if explicit != "":
        return explicit
    return AgentStatus.resolve_model_path()

func _per_agent_model_path() -> String:
    var player: String = _player_model_path()
    if player != "":
        return player
    var own: String = model_path.strip_edges()
    if own != "":
        return own
    if model_profile != null:
        var profile_path: String = model_profile.model_path.strip_edges()
        if profile_path != "":
            return profile_path
    return _configured_model_path

func _player_model_path() -> String:
    var store: LocalAgentModelSettingsStore = _player_settings()
    if store == null:
        return ""
    return store.active_model_path.strip_edges()

# The player's saved in-game model settings, loaded once. Null when Use Player Settings is off or
# nothing has been saved yet.
func _player_settings() -> LocalAgentModelSettingsStore:
    if not use_player_settings:
        return null
    if _player_store == null:
        var store: LocalAgentModelSettingsStore = ModelSettingsStore.new()
        if not store.load():
            return null
        _player_store = store
    return _player_store

# Hand the resolved GGUF to the native node, which pushes it onto the shared runtime on every think.
func _apply_model_path() -> void:
    if agent_node == null or not is_instance_valid(agent_node):
        return
    var path: String = resolve_model_path()
    if path != "":
        agent_node.default_model_path = path

func _load_runtime_model(path: String, options: Dictionary) -> bool:
    return AgentStatus.load_model(path, options)

func _get_configuration_warnings() -> PackedStringArray:
    return AgentWarnings.check(self)

func _refresh_warnings() -> void:
    if Engine.is_editor_hint():
        update_configuration_warnings()

func submit_user_message(text: String) -> void:
    _history.submit_user_message(history, text, memory_graph)
    _backstory.record("user", text)

func _on_agent_message(role, content) -> void:
    emit_signal("message_emitted", role, content)

func _on_agent_action(action, params) -> void:
    emit_signal("action_requested", action, params)

func think(prompt: String, extra_opts: Dictionary = {}) -> Dictionary:
    if not _ensure_agent_node():
        return {"ok": false, "error": "agent_unavailable"}
    _history.apply_system_prompt(history, system_prompt, agent_node)
    _apply_recall(prompt)
    if prompt != "":
        submit_user_message(prompt)   # skip empties (the LLMClient path supplies opts.messages instead)
    var opts: Dictionary = _merged_options(extra_opts)
    var result: Dictionary = _run_think(prompt, opts)
    _post_think(result)
    return result

func think_async(prompt: String, extra_opts: Dictionary = {}) -> bool:
    if not _ensure_agent_node():
        call_deferred("_emit_think_completed", {"ok": false, "error": "agent_unavailable"})
        return false
    if _jobs.is_busy():
        return false
    _jobs.reap()
    var runtime = _agent_runtime()
    if runtime == null:
        call_deferred("_emit_think_completed", {"ok": false, "error": "runtime_unavailable"})
        return false
    _history.apply_system_prompt(history, system_prompt, agent_node)
    if prompt != "":
        submit_user_message(prompt)   # skip empties (the LLMClient path supplies opts.messages instead)
    var opts: Dictionary = _merged_options(extra_opts)
    _sync_runtime_config(runtime)     # push the node's model path / runtime dir onto the shared runtime (main thread)
    var job: Dictionary = {
        "runtime": runtime,
        "request": {"prompt": prompt, "history": history.duplicate(true), "options": opts},
        "opts": opts,
        "server_model_path": _resolve_llama_server_model_path(opts),
        "runtime_dir": _current_runtime_dir(),
        # Snapshotted here (main thread) so the worker never reads the node's exports while the game
        # may be writing them.
        "agent_model_path": _per_agent_model_path(),
    }
    _jobs.start(job, _server, Callable(self, "_emit_think_completed"))
    return true

func _emit_think_completed(result: Dictionary) -> void:
    _jobs.reap()
    _post_think(result)
    emit_signal("think_completed", result)

func _agent_runtime():
    if not Engine.has_singleton("AgentRuntime"):
        return null
    return Engine.get_singleton("AgentRuntime")

# Mirror onto the shared runtime singleton the same model/dir config AgentNode.think sets each call, so
# the worker's in-process generate can load the default model. Main thread only (reads the native node).
func _sync_runtime_config(runtime) -> void:
    if agent_node == null or runtime == null:
        return
    var dmp: String = String(agent_node.get("default_model_path"))
    if dmp != "" and runtime.has_method("set_default_model_path"):
        runtime.set_default_model_path(dmp)
    var rd: String = String(agent_node.get("runtime_directory"))
    if rd != "" and runtime.has_method("set_runtime_directory"):
        runtime.set_runtime_directory(rd)

func _merged_options(extra_opts: Dictionary) -> Dictionary:
    var opts: Dictionary = load_options.duplicate(true)
    _merge_options(opts, _node_load_options())
    _merge_options(opts, inference_options)
    _merge_options(opts, _node_inference_options())
    _merge_options(opts, _player_options())
    _merge_options(opts, extra_opts)
    return opts

func _merge_options(target: Dictionary, source: Dictionary) -> void:
    for key in source.keys():
        target[key] = source[key]

# Load-time options this NODE declares: its Model Profile, with its own System Prompt over the top.
func _node_load_options() -> Dictionary:
    var opts: Dictionary = model_profile.to_options() if model_profile != null else {}
    if system_prompt.strip_edges() != "":
        opts["system_prompt"] = system_prompt
    return opts

func _node_inference_options() -> Dictionary:
    return inference.to_options() if inference != null else {}

func _player_options() -> Dictionary:
    var store: LocalAgentModelSettingsStore = _player_settings()
    return store.to_llama_options() if store != null else {}

# The blocking part of sync think(): ensure the llama-server if that backend is requested, then run the
# native AgentNode.think (which emits message_emitted — fine here, this is the main thread).
func _run_think(prompt: String, opts: Dictionary) -> Dictionary:
    if not (agent_node and is_instance_valid(agent_node)):
        return {"ok": false, "error": "agent_unavailable"}
    var server_err: Dictionary = _server.ensure_running(opts, _resolve_llama_server_model_path(opts), _current_runtime_dir())
    if not server_err.is_empty():
        return server_err
    # In-process: put THIS agent's weights in memory first. The runtime holds one model for the whole
    # process and only lazy-loads when nothing is loaded, so a per-agent model needs the explicit swap.
    if not AgentServer.is_server_backend(opts):
        _load_runtime_model(_per_agent_model_path(), opts)
    return agent_node.think(prompt, opts)

func _apply_recall(prompt: String) -> void:
    var context: String = recall_context(prompt)
    if context == "":
        return
    history.append({
        "role": "system",
        "content": "Things you remember, most relevant first:\n" + context,
    })


func _post_think(result: Dictionary) -> void:
    var text: String = String(result.get("text", ""))
    if text != "":
        _history.record_assistant_message(history, text, memory_graph)
        _backstory.record("assistant", text)
        emit_signal("model_output_received", text)
        if _should_speak_response():
            _speech.speak_async(text, voice, _current_runtime_dir())

func speak(text: String, opts: Dictionary = {}) -> bool:
    if not _ensure_agent_node():
        return false
    return _speech.speak(text, opts, voice, _current_runtime_dir())

func transcribe(opts: Dictionary = {}) -> String:
    if not _ensure_agent_node():
        return ""
    var result: Dictionary = _speech.transcribe(opts, _current_runtime_dir())
    if not result.get("ok", false):
        return ""
    var transcript: String = String(result.get("text", ""))
    if transcript != "":
        submit_user_message(transcript)
        emit_signal("model_output_received", transcript)
    return transcript

## Non-blocking transcribe(). Returns a job id, or -1 when the speech service is unavailable.
func transcribe_async(input_path: String, opts: Dictionary = {}, callback: Callable = Callable()) -> int:
    return _speech.transcribe_async(input_path, opts, _current_runtime_dir(), callback)

func clear_history() -> void:
    history.clear()
    if _ensure_agent_node() and agent_node:
        agent_node.clear_history()

func get_history() -> Array:
    if _ensure_agent_node() and agent_node:
        return agent_node.get_history()
    return history.duplicate(true)

func set_history(messages: Array) -> void:
    history.clear()
    if not _ensure_agent_node():
        return
    _history.set_messages(history, messages, agent_node)

func enqueue_action(name: String, params: Dictionary = {}):
    if _ensure_agent_node() and agent_node:
        agent_node.enqueue_action(name, params)

func _ensure_agent_node() -> bool:
    if Engine.is_editor_hint():
        return false   # @tool: never instantiate the native node or load weights inside the editor
    if agent_node and is_instance_valid(agent_node):
        return true
    if not ExtensionLoader.ensure_initialized():
        return false
    if not ClassDB.class_exists("AgentNode"):
        return false
    agent_node = ClassDB.instantiate("AgentNode")
    if agent_node == null:
        return false
    add_child(agent_node)
    _sync_agent_node_properties()
    return true

func _sync_agent_node_properties() -> void:
    if not agent_node:
        return
    var runtime_dir: String = RuntimePaths.runtime_dir()
    if runtime_dir != "":
        agent_node.runtime_directory = runtime_dir
    _apply_model_path()
    agent_node.tick_enabled = tick_enabled
    agent_node.tick_interval = tick_interval
    if db_path != "":
        agent_node.db_path = db_path
    if voice != "":
        agent_node.voice = voice

func _should_speak_response() -> bool:
    return speak_responses and _ensure_agent_node()

func _current_runtime_dir() -> String:
    if agent_node != null:
        var value = agent_node.get("runtime_directory")
        var path: String = String(value)
        if path != "":
            return path
    return RuntimePaths.runtime_dir()

func stop_managed_llama_server() -> Dictionary:
    return _server.stop_managed()

func _exit_tree() -> void:
    if Engine.is_editor_hint():
        return   # @tool: nothing was started in the editor, so there is nothing to tear down
    _jobs.join()          # a think may still be in flight on quit
    _server.stop_on_exit()

# Which weights the managed llama-server is told to serve. A per-call `server_model_path` still wins
# (that is how LocalAgentLlmService pins its own model), then this agent's own resolution order, then
# the test env var.
func _resolve_llama_server_model_path(opts: Dictionary) -> String:
    var explicit_path: String = String(opts.get("server_model_path", "")).strip_edges()
    if explicit_path != "":
        return explicit_path
    var resolved: String = resolve_model_path()
    if resolved != "":
        return resolved
    var env_path: String = OS.get_environment("LOCAL_AGENTS_TEST_GGUF").strip_edges()
    if env_path != "":
        return env_path
    return ""
