@tool
extends RefCounted

signal speech_synthesized(job_id: int, result: Dictionary)
signal transcription_completed(job_id: int, result: Dictionary)
signal job_failed(job_id: int, result: Dictionary)

const RuntimePaths := preload("res://addons/local_agents/runtime/RuntimePaths.gd")
const JOB_SPEECH := "speech"
const JOB_TRANSCRIBE := "transcription"

var _jobs := {}
var _job_counter := 1

func cancel_all_jobs() -> void:
    for job_id in _jobs.keys():
        var job: Dictionary = _jobs[job_id]
        var thread: Thread = job.get("thread")
        if thread:
            thread.wait_to_finish()
    _jobs.clear()

func synthesize_async(text: String, options: Dictionary = {}, callback: Callable = Callable()) -> int:
    var voice_id := options.get("voice_id", "")
    var runtime_dir := options.get("runtime_directory", "")
    var voice_assets := options.get("voice_assets", RuntimePaths.resolve_voice_assets(voice_id))
    if voice_assets.is_empty() and not options.has("voice_path"):
        return _complete_immediate_failure(JOB_SPEECH, {"ok": false, "error": "voice_missing"}, callback)
    var voice_path_value := options.get("voice_path", voice_assets.get("model", ""))
    var voice_path_norm := RuntimePaths.normalize_path(voice_path_value) if voice_path_value != "" else ""
    var output_value := options.get("output_path", RuntimePaths.make_tts_output_path("speech"))
    var output_norm := RuntimePaths.normalize_path(output_value) if output_value != "" else ""
    var runtime_norm := RuntimePaths.normalize_path(runtime_dir) if runtime_dir != "" else ""
    var payload := {
        "text": text,
        "voice_path": voice_path_norm,
        "voice_config": options.get("voice_config", voice_assets.get("config", "")),
        "output_path": output_norm,
        "runtime_directory": runtime_norm
    }
    return _enqueue_job(JOB_SPEECH, payload, callback)

func transcribe_async(input_path: String, options: Dictionary = {}, callback: Callable = Callable()) -> int:
    var model_path := options.get("model_path", "")
    if model_path == "":
        return _complete_immediate_failure(JOB_TRANSCRIBE, {"ok": false, "error": "whisper_model_missing"}, callback)
    var runtime_dir := options.get("runtime_directory", "")
    var runtime_norm := RuntimePaths.normalize_path(runtime_dir) if runtime_dir != "" else ""
    var input_norm := RuntimePaths.normalize_path(input_path) if input_path != "" else ""
    var output_value := options.get("output_path", "")
    var output_norm := RuntimePaths.normalize_path(output_value) if output_value != "" else ""
    var payload := {
        "input_path": input_norm,
        "model_path": RuntimePaths.normalize_path(model_path) if model_path != "" else model_path,
        "runtime_directory": runtime_norm,
        "output_path": output_norm
    }
    return _enqueue_job(JOB_TRANSCRIBE, payload, callback)

func synthesize(payload: Dictionary) -> Dictionary:
    var normalized := _normalize_payload(JOB_SPEECH, payload)
    return _invoke_runtime("synthesize_speech", normalized)

func transcribe(payload: Dictionary) -> Dictionary:
    var normalized := _normalize_payload(JOB_TRANSCRIBE, payload)
    return _invoke_runtime("transcribe_audio", normalized)

func _enqueue_job(kind: String, payload: Dictionary, callback: Callable) -> int:
    var job_id := _job_counter
    _job_counter += 1
    var thread := Thread.new()
    _jobs[job_id] = {
        "kind": kind,
        "callback": callback,
        "thread": thread,
        "payload": payload,
    }
    thread.start(Callable(self, "_execute_job").bind(job_id))
    return job_id

func _execute_job(job_id: int) -> void:
    var job: Dictionary = {}
    if _jobs.has(job_id):
        job = _jobs[job_id]
    var kind: String = String(job.get("kind", ""))
    var payload: Dictionary = job.get("payload", {})
    var result := Dictionary()
    if kind == JOB_SPEECH:
        result = _invoke_runtime("synthesize_speech", payload)
    elif kind == JOB_TRANSCRIBE:
        result = _invoke_runtime("transcribe_audio", payload)
    else:
        result = {"ok": false, "error": "unknown_job_kind"}
    call_deferred("_complete_job", job_id, result)

func _complete_job(job_id: int, result: Dictionary) -> void:
    var job: Dictionary = {}
    if _jobs.has(job_id):
        job = _jobs[job_id]
    var kind := ""
    if job != null:
        kind = job.get("kind", "")
        var thread: Thread = job.get("thread")
        if thread:
            thread.wait_to_finish()
        _jobs.erase(job_id)
        var callback: Callable = job.get("callback", Callable())
        if callback.is_valid():
            callback.call_deferred(job_id, result)
    if not result.get("ok", false):
        if kind != "":
            result["job_kind"] = kind
        emit_signal("job_failed", job_id, result)
        return
    if kind == JOB_SPEECH:
        emit_signal("speech_synthesized", job_id, result)
    elif kind == JOB_TRANSCRIBE:
        emit_signal("transcription_completed", job_id, result)

func _invoke_runtime(method: String, payload: Dictionary) -> Dictionary:
    if not Engine.has_singleton("AgentRuntime"):
        return {"ok": false, "error": "runtime_missing"}
    var runtime := Engine.get_singleton("AgentRuntime")
    if runtime == null:
        return {"ok": false, "error": "runtime_missing"}
    if not runtime.has_method(method):
        return {"ok": false, "error": "%s_unavailable" % method}
    var response = runtime.call(method, payload)
    if typeof(response) != TYPE_DICTIONARY:
        return {"ok": false, "error": "invalid_runtime_response"}
    return response

func _complete_immediate_failure(kind: String, result: Dictionary, callback: Callable) -> int:
    var job_id := _job_counter
    _job_counter += 1
    if callback.is_valid():
        callback.call_deferred(job_id, result)
    emit_signal("job_failed", job_id, result)
    return job_id

func _normalize_payload(kind: String, payload: Dictionary) -> Dictionary:
    var normalized := payload.duplicate(true)
    if normalized.has("runtime_directory"):
        var rd := normalized.get("runtime_directory", "")
        normalized["runtime_directory"] = RuntimePaths.normalize_path(rd) if rd != "" else ""
    if kind == JOB_SPEECH:
        if normalized.has("voice_path"):
            var vp := normalized.get("voice_path", "")
            normalized["voice_path"] = RuntimePaths.normalize_path(vp) if vp != "" else ""
        if normalized.has("output_path"):
            var op := normalized.get("output_path", "")
            normalized["output_path"] = RuntimePaths.normalize_path(op) if op != "" else ""
    elif kind == JOB_TRANSCRIBE:
        if normalized.has("input_path"):
            var ip := normalized.get("input_path", "")
            normalized["input_path"] = RuntimePaths.normalize_path(ip) if ip != "" else ""
        if normalized.has("model_path"):
            var mp := normalized.get("model_path", "")
            normalized["model_path"] = RuntimePaths.normalize_path(mp) if mp != "" else ""
        if normalized.has("output_path"):
            var op2 := normalized.get("output_path", "")
            normalized["output_path"] = RuntimePaths.normalize_path(op2) if op2 != "" else ""
    return normalized
