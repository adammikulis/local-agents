extends Node
class_name LocalAgent

signal model_output_received(text)
signal message_emitted(role, content)
signal action_requested(action, params)
# Emitted on the MAIN thread when a think_async() job finishes (its result Dictionary is the same
# shape as sync think()). This is the one seam that lets a caller — a creature's slow brain, the
# streamer — run inference OFF the physics frame instead of blocking on the native call.
signal think_completed(result)

var agent_node: Object
var history: Array = []
var inference_options: Dictionary = {}
const ExtensionLoader := preload("res://addons/local_agents/runtime/LocalAgentsExtensionLoader.gd")
const RuntimePaths := preload("res://addons/local_agents/runtime/RuntimePaths.gd")
const LlamaServerManager := preload("res://addons/local_agents/runtime/LlamaServerManager.gd")
const SpeechService := preload("res://addons/local_agents/runtime/audio/SpeechService.gd")

@export var db_path: String = ""
@export var voice: String = ""
@export var speak_responses: bool = false
@export var tick_enabled: bool = false
@export var tick_interval: float = 0.0
@export var max_actions_per_tick: int = 4

var _audio_player: AudioStreamPlayer
var _pending_tts_jobs := {}
var _speech_service_connected := false
var _speech_service
var _llama_server_manager = LlamaServerManager.new()
var _last_llama_server_shutdown_on_exit := true
# Worker thread for think_async(). One in-flight per agent — a second async request while one is
# running is rejected (the caller's own budget/queue decides what to do). Joined in _exit_tree.
var _think_thread: Thread = null

func _ready() -> void:
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

func configure(model_params = null, inference_params = null) -> void:
    var has_agent := _ensure_agent_node()
    if model_params:
        db_path = model_params.db_path
        voice = model_params.voice
        speak_responses = model_params.speak_responses
        tick_enabled = model_params.tick_enabled
        tick_interval = model_params.tick_interval
        max_actions_per_tick = model_params.max_actions_per_tick
        if has_agent and agent_node:
            agent_node.db_path = db_path
            agent_node.voice = voice
            agent_node.tick_enabled = tick_enabled
            agent_node.tick_interval = tick_interval
            agent_node.max_actions_per_tick = max_actions_per_tick
    if inference_params:
        inference_options = inference_params.to_options()

func submit_user_message(text: String) -> void:
    history.append({"role": "user", "content": text})

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

func _merged_options(extra_opts: Dictionary) -> Dictionary:
    var opts := inference_options.duplicate(true)
    for key in extra_opts.keys():
        opts[key] = extra_opts[key]
    return opts

# The blocking part of sync think(): ensure the llama-server if that backend is requested, then run the
# native AgentNode.think (which emits message_emitted — fine here, this is the main thread).
func _run_think(prompt: String, opts: Dictionary) -> Dictionary:
    if not (agent_node and is_instance_valid(agent_node)):
        return {"ok": false, "error": "agent_unavailable"}
    var server_err: Dictionary = _ensure_server_captured(opts, _resolve_llama_server_model_path(opts), _current_runtime_dir())
    if not server_err.is_empty():
        return server_err
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
        history.append({"role": "user", "content": transcript})
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
    var default_model := RuntimePaths.resolve_default_model()
    if default_model != "":
        agent_node.default_model_path = default_model
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

func _resolve_llama_server_model_path(opts: Dictionary) -> String:
    var explicit_path := String(opts.get("server_model_path", "")).strip_edges()
    if explicit_path != "":
        return explicit_path
    if agent_node != null:
        var default_path := String(agent_node.get("default_model_path")).strip_edges()
        if default_path != "":
            return default_path
    var runtime_default := RuntimePaths.resolve_default_model()
    if runtime_default != "":
        return runtime_default
    var env_path := OS.get_environment("LOCAL_AGENTS_TEST_GGUF").strip_edges()
    if env_path != "":
        return env_path
    return ""
