@tool
extends RefCounted
class_name LocalAgentAgentSpeech


const SpeechService: GDScript = preload("res://addons/local_agents/runtime/audio/SpeechService.gd")
const SpeechEngine: GDScript = preload("res://addons/local_agents/runtime/audio/SpeechEngine.gd")
const RuntimePaths: GDScript = preload("res://addons/local_agents/runtime/RuntimePaths.gd")

# Owns the voice model, the backend chain and the playback node. Parented to the agent by attach(),
# so it dies with it.
var _engine: SpeechEngine = null
var _parent: Node = null
var _service: SpeechService = null
var _service_connected: bool = false


## Bring speech up under `parent`. Called from the agent's _ready, so only ever at runtime - a @tool
## agent sitting in the editor never gets here.
func attach(parent: Node) -> void:
    _parent = parent
    ensure_service()


## Make sure the SpeechService exists and its failure signal is connected. Idempotent: every entry
## point calls it, because transcription can be asked for before or after _ready.
func ensure_service() -> void:
    if _service == null:
        _service = SpeechService.new()
    if _service == null:
        return
    if not _service_connected:
        if not _service.is_connected("job_failed", Callable(self, "_on_job_failed")):
            _service.connect("job_failed", Callable(self, "_on_job_failed"))
        _service_connected = true


func speak(text: String, opts: Dictionary, voice: String, runtime_dir: String) -> bool:
    var engine: SpeechEngine = _ensure_engine(voice, runtime_dir)
    if engine == null:
        push_warning("Local Agents cannot speak without a running scene tree. Call speak() from a node that is inside the tree.")
        return false
    return engine.speak_blocking(text, opts)


## Say a finished reply out loud without blocking the frame: hand the line to the engine, which
## queues it, synthesizes off the main thread and plays the result when it lands.
func speak_async(text: String, voice: String, runtime_dir: String) -> void:
    var engine: SpeechEngine = _ensure_engine(voice, runtime_dir)
    if engine == null:
        push_warning("Local Agents cannot speak without a running scene tree. The reply was not spoken.")
        return
    engine.speak(text)


func transcribe(opts: Dictionary, runtime_dir: String) -> Dictionary:
    ensure_service()
    if _service == null:
        return {}
    var payload: Dictionary = opts.duplicate(true)
    payload["runtime_directory"] = _normalized_runtime_dir(runtime_dir)
    return _service.transcribe(payload)


## Non-blocking transcription (LocalAgent.transcribe_async). Returns the job id, or -1 when the service is
## unavailable.
func transcribe_async(input_path: String, opts: Dictionary, runtime_dir: String, callback: Callable) -> int:
    ensure_service()
    if _service == null:
        return -1
    var payload: Dictionary = opts.duplicate(true)
    payload["runtime_directory"] = _normalized_runtime_dir(runtime_dir)
    payload["model_path"] = payload.get("model_path", "")
    return _service.transcribe_async(input_path, payload, callback)


func backend_name(voice: String, runtime_dir: String) -> String:
    var engine: SpeechEngine = _ensure_engine(voice, runtime_dir)
    if engine == null:
        return "none"
    return engine.backend_name()


func _ensure_engine(voice: String, runtime_dir: String) -> SpeechEngine:
    if _engine != null and is_instance_valid(_engine):
        if voice != "":
            _engine.set_voice(voice)
        _engine.set_runtime_directory(_normalized_runtime_dir(runtime_dir))
        return _engine
    var host: Node = _engine_host()
    if host == null:
        return null
    _engine = SpeechEngine.new()
    _engine.name = "SpeechEngine"
    host.add_child(_engine)
    _engine.setup({
        "voice_id": voice,
        "runtime_directory": _normalized_runtime_dir(runtime_dir),
    })
    return _engine


# The agent when attach() ran, otherwise the scene root. Null means there is no scene tree at all,
# which is a RefCounted-only context where nothing can play anyway.
func _engine_host() -> Node:
    if _parent != null and is_instance_valid(_parent):
        return _parent
    var loop: MainLoop = Engine.get_main_loop()
    if loop is SceneTree:
        return (loop as SceneTree).root
    return null


# Any speech job (transcription) the service gave up on.
func _on_job_failed(job_id: int, result: Dictionary) -> void:
    push_warning("Speech service job %d failed: %s" % [job_id, String(result.get("error", "speech_job_failed"))])


# The service wants an absolute runtime directory, and "" when there is none to give.
func _normalized_runtime_dir(runtime_dir: String) -> String:
    return RuntimePaths.normalize_path(runtime_dir) if runtime_dir != "" else ""
