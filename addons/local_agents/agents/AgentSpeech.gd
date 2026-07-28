@tool
extends RefCounted
class_name LocalAgentAgentSpeech

## Everything LocalAgent does with sound: the SpeechService wiring, the AudioStreamPlayer that plays a
## generated reply back, and the map of in-flight TTS jobs that connects a finished synthesis to the
## file it wrote.
##
## Split out of Agent.gd so the node keeps the inference API. The agent owns one of these and hands it
## the values it needs per call (the voice id, the runtime directory), so nothing here reads the node's
## exports - the only node this file touches is the AudioStreamPlayer it created itself.
##
## (Explicit types only - project rule: no ':=' inferred typing.)

const SpeechService: GDScript = preload("res://addons/local_agents/runtime/audio/SpeechService.gd")
const RuntimePaths: GDScript = preload("res://addons/local_agents/runtime/RuntimePaths.gd")

# Plays back the .wav Piper writes. Created by attach() and parented to the agent, so it dies with it.
var _audio_player: AudioStreamPlayer = null
# job id -> {relative_output, absolute_output}: where the synthesis job in flight was told to write.
var _pending_jobs: Dictionary = {}
var _service: SpeechService = null
var _service_connected: bool = false


## Create the playback node under `parent` and bring the speech service up. Called from the agent's
## _ready, so only ever at runtime - a @tool agent sitting in the editor never gets here.
func attach(parent: Node) -> void:
    if _audio_player == null:
        _audio_player = AudioStreamPlayer.new()
        _audio_player.name = "TTSPlayer"
        parent.add_child(_audio_player)
    ensure_service()


## Make sure the SpeechService exists and its failure signal is connected. Idempotent: every entry
## point calls it, because speech can be asked for before or after _ready.
func ensure_service() -> void:
    if _service == null:
        _service = SpeechService.new()
    if _service == null:
        return
    if not _service_connected:
        if not _service.is_connected("job_failed", Callable(self, "_on_job_failed")):
            _service.connect("job_failed", Callable(self, "_on_job_failed"))
        _service_connected = true


## Blocking synthesis (LocalAgent.say): true when the service accepted the request and produced audio.
func say(text: String, opts: Dictionary, voice: String, runtime_dir: String) -> bool:
    ensure_service()
    if _service == null:
        return false
    var payload: Dictionary = opts.duplicate(true)
    payload["voice_id"] = voice
    payload["runtime_directory"] = _normalized_runtime_dir(runtime_dir)
    payload["text"] = text
    var result: Dictionary = _service.synthesize(payload)
    return bool(result.get("ok", false))


## Blocking transcription (LocalAgent.listen). Returns the service's raw result - the agent decides
## what to do with the transcript, because recording it in history and re-emitting it are its job, not
## this file's. An empty dictionary means the service was unavailable, which reads as "not ok".
func transcribe(opts: Dictionary, runtime_dir: String) -> Dictionary:
    ensure_service()
    if _service == null:
        return {}
    var payload: Dictionary = opts.duplicate(true)
    payload["runtime_directory"] = _normalized_runtime_dir(runtime_dir)
    return _service.transcribe(payload)


## Non-blocking transcription (LocalAgent.listen_async). Returns the job id, or -1 when the service is
## unavailable.
func transcribe_async(input_path: String, opts: Dictionary, runtime_dir: String, callback: Callable) -> int:
    ensure_service()
    if _service == null:
        return -1
    var payload: Dictionary = opts.duplicate(true)
    payload["runtime_directory"] = _normalized_runtime_dir(runtime_dir)
    payload["model_path"] = payload.get("model_path", "")
    return _service.transcribe_async(input_path, payload, callback)


## Say a finished reply out loud without blocking the frame: kick Piper off, and play whatever it
## wrote when the job reports back. A missing voice is a warning, not an error - an agent whose voice
## assets are not installed still thinks and still emits its reply as text.
func speak_async(text: String, voice: String, runtime_dir: String) -> void:
    ensure_service()
    if _service == null:
        push_warning("Speech service unavailable; cannot synthesize speech")
        return
    var voice_report: Dictionary = RuntimePaths.voice_asset_report(voice)
    if not bool(voice_report.get("ok", false)):
        var checked: PackedStringArray = PackedStringArray(voice_report.get("candidates", PackedStringArray()))
        push_warning("Voice assets not found for '%s'. Checked: %s" % [voice, ", ".join(checked)])
        return
    var output_rel: String = RuntimePaths.make_tts_output_path("local_agents")
    var output_abs: String = ProjectSettings.globalize_path(output_rel)
    var options: Dictionary = {
        "voice_id": voice,
        "voice_path": String(voice_report.get("model", "")),
        "voice_config": String(voice_report.get("config", "")),
        "output_path": output_abs,
        "runtime_directory": _normalized_runtime_dir(runtime_dir),
    }
    var job_id: int = _service.synthesize_async(text, options, Callable(self, "_on_job_finished"))
    _pending_jobs[job_id] = {
        "relative_output": output_rel,
        "absolute_output": output_abs,
    }


# A synthesis job finished. Prefer the path we asked for; fall back to the one the service reports,
# localized when there is a project to localize against.
func _on_job_finished(job_id: int, result: Dictionary) -> void:
    var job: Dictionary = _pending_jobs.get(job_id, {})
    _pending_jobs.erase(job_id)
    if not bool(result.get("ok", false)):
        push_warning("Speech synthesis failed (%s)" % String(result.get("error", "tts_failed")))
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
    _play(rel_path)


# Any speech job (synthesis or transcription) the service gave up on.
func _on_job_failed(job_id: int, result: Dictionary) -> void:
    if _pending_jobs.has(job_id):
        _pending_jobs.erase(job_id)
    push_warning("Speech service job %d failed: %s" % [job_id, String(result.get("error", "speech_job_failed"))])


func _play(user_path: String) -> void:
    if _audio_player == null:
        return
    if _audio_player.playing:
        _audio_player.stop()
    var stream: Resource = ResourceLoader.load(user_path)
    if stream is AudioStream:
        _audio_player.stream = stream
        _audio_player.play()
    else:
        push_warning("Failed to load generated audio at %s" % user_path)


# The service wants an absolute runtime directory, and "" when there is none to give.
func _normalized_runtime_dir(runtime_dir: String) -> String:
    return RuntimePaths.normalize_path(runtime_dir) if runtime_dir != "" else ""
