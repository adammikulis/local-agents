@tool
extends Node
class_name LocalAgent

## A local LLM agent you can use without writing any code: drop this node into a scene, pick a
## `.gguf` in the inspector, then call think() — or turn on Autonomy and let it act by itself.
##
## Which weights load is layered, most specific first: the player's in-game model manager (when Use
## Player Settings is on) beats this node's Model Path, which beats its Model Profile, which beats
## whatever configure() was handed, which beats the project-wide default
## (Project Settings > local_agents/model/default_path, resolved by LocalAgentStatus).
##
## Sampling and load-time knobs are kept in two separate dictionaries — see load_options /
## inference_options below — because "which weights, loaded how" and "how to sample from them" have
## different lifetimes.
##
## @tool is on so the node can report configuration warnings while you edit the scene. Every
## lifecycle callback therefore opens with an `Engine.is_editor_hint()` guard, and _ensure_agent_node()
## refuses outright in the editor: an agent sitting in an open scene must never boot the native
## runtime or load a model inside the editor.
##
## (New code here uses explicit types — project rule: no ':=' inferred typing.)

signal model_output_received(text)
signal message_emitted(role, content)
signal action_requested(action, params)
# Emitted on the MAIN thread when a think_async() job finishes (its result Dictionary is the same
# shape as sync think()). This is the one seam that lets a caller — a creature's slow brain, the
# streamer — run inference OFF the physics frame instead of blocking on the native call.
signal think_completed(result)

var agent_node: Object
var history: Array = []
## Sampling settings (temperature, penalties, backend). configure() REPLACES this wholesale when it
## is handed an inference preset, so nothing else may store state here.
var inference_options: Dictionary = {}
## Model LOAD-time knobs: context window, threads, GPU layers, system prompt. Deliberately a separate
## Dictionary from inference_options, because "which weights, loaded how" and "how to sample from
## them" are different concerns with different lifetimes — a user switching sampling presets must not
## silently drop their context size. Kept out of configure()'s replace path for exactly that reason.
var load_options: Dictionary = {}
const ExtensionLoader := preload("res://addons/local_agents/runtime/LocalAgentExtensionLoader.gd")
const RuntimePaths := preload("res://addons/local_agents/runtime/RuntimePaths.gd")
const LlamaServerManager := preload("res://addons/local_agents/runtime/LlamaServerManager.gd")
const SpeechService := preload("res://addons/local_agents/runtime/audio/SpeechService.gd")
const AgentStatus: GDScript = preload("res://addons/local_agents/runtime/AgentStatus.gd")
const AgentWarnings: GDScript = preload("res://addons/local_agents/agents/AgentWarnings.gd")
const ModelSettingsStore: GDScript = preload("res://addons/local_agents/runtime/ModelSettingsStore.gd")

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

## How the model is loaded: context window and GPU layers. Share one profile between agents to load
## the weights once. Empty uses the project defaults.
## These knobs only apply when this agent also names a Model Path (here or on the profile) — without
## one the runtime lazy-loads with its own defaults and the profile is ignored. The profile's
## `threads` field is not implemented by the runtime yet.
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

## Piper voice id under addons/local_agents/voices — a folder or .onnx basename, e.g. "en_US-amy".
## Empty means this agent never speaks.
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

## Let the agent act on its own — the native runtime ticks it and it may emit action_requested
## without anyone calling think(). Off means it only ever responds when asked.
@export var tick_enabled: bool = false:
    set(value):
        tick_enabled = value
        if agent_node != null and is_instance_valid(agent_node):
            agent_node.tick_enabled = tick_enabled
        _refresh_warnings()

## Seconds of game time between autonomous ticks. 0 DISABLES ticking — the native runtime returns
## early on a non-positive interval (AgentNode.cpp:56), so an agent set to 0 never acts at all.
@export_range(0.0, 60.0, 0.05, "or_greater", "suffix:s") var tick_interval: float = 1.0:
    set(value):
        tick_interval = value
        if agent_node != null and is_instance_valid(agent_node):
            agent_node.tick_interval = tick_interval
        _refresh_warnings()

## Reserved. Forwarded to the native agent node, which stores it and does not yet act on it: a tick
## emits exactly one action today, so there is nothing to cap. Kept so scenes do not lose the value
## when the native side grows multi-action plans.
@export_range(1, 32, 1) var max_actions_per_tick: int = 4:
    set(value):
        max_actions_per_tick = value
        if agent_node != null and is_instance_valid(agent_node):
            agent_node.max_actions_per_tick = max_actions_per_tick

@export_group("Memory")

## Knowledge graph this agent writes its conversation into: every message it is given and every reply
## it produces becomes a node, chained to the one before it by a "then" edge. Empty keeps no graph.
## Two agents handed the SAME graph resource write into one shared record.
@export var memory_graph: LocalAgentGraph = null

## Reserved. Handed to the native agent node, which stores it and does not read it yet — conversation
## persistence currently goes through ConversationStore, not this. Kept because it is part of the
## native node's published surface.
@export_global_file("*.db", "*.sqlite", "*.sqlite3") var db_path: String = "":
    set(value):
        db_path = value
        if agent_node != null and is_instance_valid(agent_node) and db_path != "":
            agent_node.db_path = db_path

var _audio_player: AudioStreamPlayer
var _pending_tts_jobs := {}
var _speech_service_connected := false
var _speech_service
var _llama_server_manager = LlamaServerManager.new()
var _last_llama_server_shutdown_on_exit := true
# Worker thread for think_async(). One in-flight per agent — a second async request while one is
# running is rejected (the caller's own budget/queue decides what to do). Joined in _exit_tree.
var _think_thread: Thread = null
# The player's saved in-game model settings, read once on first use. Null until Use Player Settings
# is on and a settings file exists.
var _player_store: LocalAgentModelSettingsStore = null
# model_path of the profile configure() was last handed. Sits below this node's own Model Path in the
# resolution order and above the project-wide default.
var _configured_model_path: String = ""
# Newest node written into memory_graph, so the next message can be chained onto it.
var _last_memory_node_id: int = -1

func _ready() -> void:
    if Engine.is_editor_hint():
        return   # @tool: an agent in an open scene must not boot the runtime inside the editor
    if not _ensure_agent_node():
        push_warning("Local Agents extension unavailable; agent node inactive")
        return
    _audio_player = AudioStreamPlayer.new()
    _audio_player.name = "TTSPlayer"
    add_child(_audio_player)
    if _speech_service == null:
        _speech_service = SpeechService.new()
    if not agent_node.is_connected("message_emitted", Callable(self, "_on_agent_message")):
        agent_node.connect("message_emitted", Callable(self, "_on_agent_message"))
    if not agent_node.is_connected("action_requested", Callable(self, "_on_agent_action")):
        agent_node.connect("action_requested", Callable(self, "_on_agent_action"))
    if is_inside_tree():
        _register_with_manager()
    else:
        call_deferred("_register_with_manager")
    _ensure_speech_service()
    # A llama-server keeps the weights in its own process, so an in-process preload would only load
    # them a second time for nothing.
    if preload_model and not _is_llama_server_backend(_merged_options({})):
        ensure_model_loaded()

func _register_with_manager() -> void:
    var manager = get_node_or_null("/root/AgentManager")
    if manager:
        manager.register_agent(self)

func _ensure_speech_service() -> void:
    if _speech_service == null:
        _speech_service = SpeechService.new()
    if _speech_service == null:
        return
    if not _speech_service_connected:
        var service_obj: Object = _speech_service
        if not service_obj.is_connected("job_failed", Callable(self, "_on_speech_job_failed")):
            service_obj.connect("job_failed", Callable(self, "_on_speech_job_failed"))
        _speech_service_connected = true

## Applies a saved model profile and/or sampling preset from outside the scene. AgentManager calls it
## with the project-wide configs — `configure(null, preset)` — and the editor panels call it when you
## pick a different one.
##
## The profile lands in `load_options` and the preset in `inference_options`, never both in one
## dictionary: `inference_options` is REPLACED wholesale here, so anything durable (context size,
## threads, GPU layers, the system prompt) would be dropped the moment a sampling preset was applied.
##
## Neither argument overrides this node's own Model Profile / Inference resources — see
## _merged_options() for the whole precedence chain.
func configure(model_profile_config: LocalAgentModelProfile = null, inference_params: LocalAgentInferenceParams = null) -> void:
    _ensure_agent_node()
    if model_profile_config != null:
        load_options = model_profile_config.to_options()
        _configured_model_path = model_profile_config.model_path.strip_edges()
        _apply_model_path()
    if inference_params != null:
        inference_options = inference_params.to_options()

## True when the native runtime is available at all: the extension is loaded and the AgentManager
## autoload is registered. Whether a MODEL is ready is a separate question — see is_model_ready().
##
## Gates on those two facts rather than LocalAgentStatus.is_ready(), which is false for purely
## advisory warnings (a missing Piper voice) that must not stop an agent from thinking.
func is_runtime_ready() -> bool:
    var state: Dictionary = AgentStatus.check()
    return bool(state["extension_ok"]) and bool(state["autoload_ok"])

## True when this agent has weights to use AND the runtime currently holds a model in memory.
func is_model_ready() -> bool:
    return resolve_model_path() != "" and bool(AgentStatus.check()["model_loaded"])

## Puts this agent's weights in memory, loading them if they are not there yet. Returns false when
## the runtime is unavailable or no model resolves at all. Blocks while the file loads.
##
## When the node names no model of its own, this is exactly LocalAgentStatus.ensure_model_loaded();
## when it does, that path is loaded in place of whatever the shared runtime is holding.
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

# The model THIS agent insists on, ignoring the project-wide fallback: the player's in-game choice,
# then Model Path, then the Model Profile's, then whatever configure() was handed. "" means "no
# per-agent override", in which case the runtime's own lazy default-model load is already right.
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

# Put `path` in memory in place of whatever the runtime currently holds, and report whether that
# model is resident afterwards. Safe to call from the think_async worker: it touches the runtime
# singleton and the static tracking pair, never the scene.
# Delegates to LocalAgentStatus, which owns the "what is resident" answer for the whole addon.
# This used to keep its own static cache, but that cache was only written here while at least five
# other paths loaded models without touching it (AgentStatus.ensure_model_loaded, three examples,
# ChatController) — so a pinned agent could find the cache saying "yours" while the runtime actually
# held someone else's weights, and generate on the wrong model with no error.
func _load_runtime_model(path: String, options: Dictionary) -> bool:
    return AgentStatus.load_model(path, options)

func _get_configuration_warnings() -> PackedStringArray:
    return AgentWarnings.check(self)

func _refresh_warnings() -> void:
    if Engine.is_editor_hint():
        update_configuration_warnings()

func submit_user_message(text: String) -> void:
    history.append({"role": "user", "content": text})
    _record_in_memory_graph("user", text)

# Put this agent's system_prompt at the front of its conversation.
#
# It has to go in the HISTORY, not in the options dictionary. The native runtime never reads
# options["system_prompt"] — it has a single `system_prompt_` member on the shared AgentRuntime
# singleton, which it injects only when the history contains no system message of its own
# (AgentRuntime.cpp:1643). So routing a per-agent prompt through set_system_prompt() would make
# every agent in the scene share one persona, and routing it through the options did nothing at all.
# A system message at index 0 is per-agent, and it also suppresses the runtime's generic default.
func _apply_system_prompt() -> void:
    var wanted: String = system_prompt.strip_edges()
    if wanted == "":
        return
    var first_is_system: bool = false
    if history.size() > 0 and history[0] is Dictionary:
        first_is_system = String((history[0] as Dictionary).get("role", "")) == "system"
    if first_is_system:
        var current: Dictionary = history[0]
        if String(current.get("content", "")) == wanted:
            return                      # already in place; do not churn the native history
        current["content"] = wanted
    else:
        history.insert(0, {"role": "system", "content": wanted})
    # The sync path reads the NATIVE node's own history (AgentNode::think uses get_history()), so the
    # GDScript-side edit has to be mirrored across or think() would not see it.
    _sync_history_to_agent_node()

func _sync_history_to_agent_node() -> void:
    if not (agent_node and is_instance_valid(agent_node)):
        return
    agent_node.clear_history()
    for entry_variant in history:
        if not (entry_variant is Dictionary):
            continue
        var entry: Dictionary = entry_variant
        agent_node.add_message(String(entry.get("role", "user")), String(entry.get("content", "")))

# Append one message to the Memory Graph, chained to the previous one by a "then" edge so the graph
# reads back as the conversation in order. Does nothing when no graph is assigned.
func _record_in_memory_graph(role: String, content: String) -> void:
    if memory_graph == null or content.strip_edges() == "":
        return
    var entry: LocalAgentGraphNode = memory_graph.add_node(role, {"role": role, "content": content})
    if entry == null:
        return
    if _last_memory_node_id >= 0:
        memory_graph.add_edge(_last_memory_node_id, entry.id, "then")
    _last_memory_node_id = entry.id

# Re-emit the native AgentNode signals on this wrapper so scenes can listen to
# LocalAgent directly (message_emitted / action_requested). These are the
# handlers connected in _ready(); without them enqueue_action would raise a
# "nonexistent function" error and the wrapper signals would never fire.
func _on_agent_message(role, content) -> void:
    emit_signal("message_emitted", role, content)

func _on_agent_action(action, params) -> void:
    emit_signal("action_requested", action, params)

func think(prompt: String, extra_opts: Dictionary = {}) -> Dictionary:
    if not _ensure_agent_node():
        return {"ok": false, "error": "agent_unavailable"}
    _apply_system_prompt()
    if prompt != "":
        submit_user_message(prompt)   # skip empties (the LLMClient path supplies opts.messages instead)
    var opts := _merged_options(extra_opts)
    var result: Dictionary = _run_think(prompt, opts)
    _post_think(result)
    return result

# Run inference OFF the physics frame: the blocking work is done on a worker Thread and the result is
# delivered on the MAIN thread via the think_completed signal (never blocks rendering). Returns true if
# a job was started; false if the agent is unavailable or one is already in flight (the caller — e.g. the
# slow-brain scheduler's global budget — decides what to do when rejected).
#
# The async worker calls the signal-FREE AgentRuntime.generate() directly instead of AgentNode.think():
# think() emits message_emitted on the node, and Godot forbids emitting a node's signals from a worker
# thread. generate() is the same inference under the hood (both backends, mutex-guarded) but pure
# data-in/data-out, so it is safe off-thread. Every node read (model path, runtime dir, history) is
# snapshotted HERE on the main thread and handed to the worker as plain values.
func think_async(prompt: String, extra_opts: Dictionary = {}) -> bool:
    if not _ensure_agent_node():
        call_deferred("_emit_think_completed", {"ok": false, "error": "agent_unavailable"})
        return false
    if _think_thread != null and _think_thread.is_alive():
        return false
    if _think_thread != null:
        _think_thread.wait_to_finish()
        _think_thread = null
    var runtime = _agent_runtime()
    if runtime == null:
        call_deferred("_emit_think_completed", {"ok": false, "error": "runtime_unavailable"})
        return false
    _apply_system_prompt()
    if prompt != "":
        submit_user_message(prompt)   # skip empties (the LLMClient path supplies opts.messages instead)
    var opts := _merged_options(extra_opts)
    _sync_runtime_config(runtime)     # push the node's model path / runtime dir onto the shared runtime (main thread)
    var job := {
        "runtime": runtime,
        "request": {"prompt": prompt, "history": history.duplicate(true), "options": opts},
        "opts": opts,
        "server_model_path": _resolve_llama_server_model_path(opts),
        "runtime_dir": _current_runtime_dir(),
        # Snapshotted here (main thread) so the worker never reads the node's exports while the game
        # may be writing them.
        "agent_model_path": _per_agent_model_path(),
    }
    _think_thread = Thread.new()
    _think_thread.start(Callable(self, "_generate_worker").bind(job))
    return true

# Worker-thread body: ensure the llama-server if needed (HTTP/process only — no scene touch), then run
# the signal-free generate(). All inputs are pre-snapshotted plain values (no node access here).
func _generate_worker(job: Dictionary) -> void:
    var opts: Dictionary = job.get("opts", {})
    var server_err: Dictionary = _ensure_server_captured(opts, String(job.get("server_model_path", "")), String(job.get("runtime_dir", "")))
    if not server_err.is_empty():
        call_deferred("_emit_think_completed", server_err)
        return
    var runtime = job.get("runtime", null)
    if runtime == null:
        call_deferred("_emit_think_completed", {"ok": false, "error": "runtime_unavailable"})
        return
    # Same per-agent model swap as the sync path, done HERE so the load cost stays off the frame.
    if not _is_llama_server_backend(opts):
        _load_runtime_model(String(job.get("agent_model_path", "")), opts)
    var result: Dictionary = runtime.generate(job.get("request", {}))
    call_deferred("_emit_think_completed", result)

func _emit_think_completed(result: Dictionary) -> void:
    if _think_thread != null and not _think_thread.is_alive():
        _think_thread.wait_to_finish()
        _think_thread = null
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
    var dmp := String(agent_node.get("default_model_path"))
    if dmp != "" and runtime.has_method("set_default_model_path"):
        runtime.set_default_model_path(dmp)
    var rd := String(agent_node.get("runtime_directory"))
    if rd != "" and runtime.has_method("set_runtime_directory"):
        runtime.set_runtime_directory(rd)

# Precedence, least specific layer first:
#   1. load_options          — load-time knobs configure()/AgentManager pushed in project-wide
#   2. this node's Model Profile, with its own System Prompt on top
#   3. inference_options     — the sampling preset configure() was handed
#   4. this node's Inference resource
#   5. the player's in-game model settings, when Use Player Settings is on
#   6. this call's own overrides
# Layers 1-2 and 3-4 stay in that order (node beats project-wide) so a scene-authored agent is never
# silently retuned by a global preset.
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
    var server_err: Dictionary = _ensure_server_captured(opts, _resolve_llama_server_model_path(opts), _current_runtime_dir())
    if not server_err.is_empty():
        return server_err
    # In-process: put THIS agent's weights in memory first. The runtime holds one model for the whole
    # process and only lazy-loads when nothing is loaded, so a per-agent model needs the explicit swap.
    if not _is_llama_server_backend(opts):
        _load_runtime_model(_per_agent_model_path(), opts)
    return agent_node.think(prompt, opts)

# Ensure the managed llama-server is up for a llama_server-backend request. Returns {} when not needed
# or already running, else an error dict. Takes pre-resolved model_path + runtime_dir so it is callable
# from either the main thread (sync) or the worker (async) without touching the node.
func _ensure_server_captured(opts: Dictionary, model_path: String, runtime_dir: String) -> Dictionary:
    if not _is_llama_server_backend(opts):
        return {}
    var autostart := bool(opts.get("server_autostart", true))
    _last_llama_server_shutdown_on_exit = bool(opts.get("server_shutdown_on_exit", true))
    if not autostart:
        return {}
    var lifecycle = _llama_server_manager.ensure_running(opts, model_path, runtime_dir)
    if not bool(lifecycle.get("ok", false)):
        return {
            "ok": false,
            "provider": "llama_server",
            "error": String(lifecycle.get("error", "llama_server_unavailable")),
            "lifecycle": lifecycle,
        }
    return {}

# Main-thread side effects of a completed think (sync or async): record the reply + emit + optionally speak.
func _post_think(result: Dictionary) -> void:
    var text := String(result.get("text", ""))
    if text != "":
        history.append({"role": "assistant", "content": text})
        _record_in_memory_graph("assistant", text)
        emit_signal("model_output_received", text)
        if _should_speak_response():
            _speak_text_async(text)

func say(text: String, opts: Dictionary = {}) -> bool:
    if not _ensure_agent_node():
        return false
    _ensure_speech_service()
    if _speech_service == null:
        return false
    var service = _speech_service
    var payload = opts.duplicate(true)
    payload["voice_id"] = voice
    var runtime_dir: String = _current_runtime_dir()
    payload["runtime_directory"] = RuntimePaths.normalize_path(runtime_dir) if runtime_dir != "" else ""
    payload["text"] = text
    var result = service.synthesize(payload)
    return result.get("ok", false)

func listen(opts: Dictionary = {}) -> String:
    if not _ensure_agent_node():
        return ""
    _ensure_speech_service()
    if _speech_service == null:
        return ""
    var service = _speech_service
    var payload = opts.duplicate(true)
    var runtime_dir: String = _current_runtime_dir()
    payload["runtime_directory"] = RuntimePaths.normalize_path(runtime_dir) if runtime_dir != "" else ""
    var result = service.transcribe(payload)
    if not result.get("ok", false):
        return ""
    var transcript: String = String(result.get("text", ""))
    if transcript != "":
        submit_user_message(transcript)
        emit_signal("model_output_received", transcript)
    return transcript

func listen_async(input_path: String, opts: Dictionary = {}, callback: Callable = Callable()) -> int:
    _ensure_speech_service()
    if _speech_service == null:
        return -1
    var service = _speech_service
    var payload = opts.duplicate(true)
    var runtime_dir: String = _current_runtime_dir()
    payload["runtime_directory"] = RuntimePaths.normalize_path(runtime_dir) if runtime_dir != "" else ""
    payload["model_path"] = payload.get("model_path", "")
    return service.transcribe_async(input_path, payload, callback)

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
    agent_node.clear_history()
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
        agent_node.add_message(role, content)

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
    var runtime_dir := RuntimePaths.runtime_dir()
    if runtime_dir != "":
        agent_node.runtime_directory = runtime_dir
    _apply_model_path()
    agent_node.tick_enabled = tick_enabled
    agent_node.tick_interval = tick_interval
    agent_node.max_actions_per_tick = max_actions_per_tick
    if db_path != "":
        agent_node.db_path = db_path
    if voice != "":
        agent_node.voice = voice

func _should_speak_response() -> bool:
    return speak_responses and _ensure_agent_node()

func _speak_text_async(text: String) -> void:
    _ensure_speech_service()
    if _speech_service == null:
        push_warning("Speech service unavailable; cannot synthesize speech")
        return
    var service = _speech_service
    var voice_report := RuntimePaths.voice_asset_report(voice)
    if not voice_report.get("ok", false):
        var checked := PackedStringArray(voice_report.get("candidates", PackedStringArray()))
        push_warning("Voice assets not found for '%s'. Checked: %s" % [voice, ", ".join(checked)])
        return
    var assets := {
        "model": voice_report.get("model", ""),
        "config": voice_report.get("config", ""),
    }
    var output_rel := RuntimePaths.make_tts_output_path("local_agents")
    var output_abs := ProjectSettings.globalize_path(output_rel)
    var runtime_dir: String = _current_runtime_dir()
    var runtime_abs := RuntimePaths.normalize_path(runtime_dir) if runtime_dir != "" else ""
    var options := {
        "voice_id": voice,
        "voice_path": assets.get("model", ""),
        "voice_config": assets.get("config", ""),
        "output_path": output_abs,
        "runtime_directory": runtime_abs,
    }
    var job_id = service.synthesize_async(text, options, Callable(self, "_on_tts_job_finished"))
    _pending_tts_jobs[job_id] = {
        "relative_output": output_rel,
        "absolute_output": output_abs,
    }

func _play_tts_audio(user_path: String) -> void:
    if _audio_player == null:
        return
    if _audio_player.playing:
        _audio_player.stop()
    var stream := ResourceLoader.load(user_path)
    if stream is AudioStream:
        _audio_player.stream = stream
        _audio_player.play()
    else:
        push_warning("Failed to load generated audio at %s" % user_path)

func _on_tts_job_finished(job_id: int, result: Dictionary) -> void:
    var job := _pending_tts_jobs.get(job_id, {})
    _pending_tts_jobs.erase(job_id)
    if not result.get("ok", false):
        var error := result.get("error", "tts_failed")
        push_warning("Speech synthesis failed (%s)" % error)
        return
    var rel_path: String = String(job.get("relative_output", ""))
    var resolved: String = String(result.get("output_path", ""))
    if rel_path == "" and resolved != "":
        if ProjectSettings.has_setting("application/config/name"):
            rel_path = ProjectSettings.localize_path(resolved)
        else:
            rel_path = resolved
    if rel_path == "":
        rel_path = "user://local_agents/tts"
    _play_tts_audio(rel_path)

func _on_speech_job_failed(job_id: int, result: Dictionary) -> void:
    if _pending_tts_jobs.has(job_id):
        _pending_tts_jobs.erase(job_id)
    var error := result.get("error", "speech_job_failed")
    push_warning("Speech service job %d failed: %s" % [job_id, error])

func _current_runtime_dir() -> String:
    if agent_node != null:
        var value = agent_node.get("runtime_directory")
        var path := String(value)
        if path != "":
            return path
    return RuntimePaths.runtime_dir()

func stop_managed_llama_server() -> Dictionary:
    return _llama_server_manager.stop_managed()

func _exit_tree() -> void:
    if Engine.is_editor_hint():
        return   # @tool: nothing was started in the editor, so there is nothing to tear down
    if _think_thread != null:
        _think_thread.wait_to_finish()   # a think may still be in flight on quit
        _think_thread = null
    if _last_llama_server_shutdown_on_exit:
        _llama_server_manager.stop_managed()

func _is_llama_server_backend(opts: Dictionary) -> bool:
    var backend := String(opts.get("backend", "")).to_lower().strip_edges()
    return backend in [
        "llama_server",
        "llama-server",
        "llama.cpp_server",
        "llama.cpp-http",
        "llama_cpp_http",
        "llama_http",
    ]

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
