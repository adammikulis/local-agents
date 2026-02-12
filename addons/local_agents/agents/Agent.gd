extends Node
class_name LocalAgentsAgent

signal model_output_received(text)
signal message_emitted(role, content)
signal action_requested(action, params)

var agent_node: Object
var history: Array = []
var inference_options: Dictionary = {}
const ExtensionLoader := preload("res://addons/local_agents/runtime/LocalAgentsExtensionLoader.gd")
const RuntimePaths := preload("res://addons/local_agents/runtime/RuntimePaths.gd")
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

func think(prompt: String, extra_opts: Dictionary = {}) -> Dictionary:
    if not _ensure_agent_node():
        return {"ok": false, "error": "agent_unavailable"}
    submit_user_message(prompt)
    var opts := inference_options.duplicate(true)
    for key in extra_opts.keys():
        opts[key] = extra_opts[key]
    var result: Dictionary = agent_node.think(prompt, opts)
    var text := result.get("text", "")
    if text != "":
        history.append({"role": "assistant", "content": text})
        emit_signal("model_output_received", text)
        if _should_speak_response():
            _speak_text_async(text)
    return result

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
