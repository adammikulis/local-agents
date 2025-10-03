@tool
extends Control
class_name LocalAgentsDownloadController

@export var output_log: RichTextLabel

@onready var status_label: Label = %StatusLabel
@onready var download_all_button: Button = %DownloadAllButton
@onready var download_models_button: Button = %DownloadModelsButton
@onready var download_voices_button: Button = %DownloadVoicesButton
@onready var clean_button: Button = %CleanButton

const FETCH_SCRIPT := "res://addons/local_agents/gdextensions/localagents/scripts/fetch_dependencies.sh"
const MODEL_SERVICE := preload("res://addons/local_agents/controllers/ModelDownloadService.gd")

const JOB_SCRIPT := "script"
const JOB_MODEL := "model"
const JOB_COMPOSITE := "composite"

var _worker: Thread
var _is_running := false
var _pending_job: Dictionary = {}
var _model_service := MODEL_SERVICE.new()

func _ready() -> void:
    _reset_output()
    _set_running_state(false, "Idle")

func _exit_tree() -> void:
    if _worker:
        _worker.wait_to_finish()
        _worker = null

func download_all() -> void:
    var request := _model_service.create_request()
    if request.is_empty():
        push_error("Default model configuration unavailable")
        return
    _start_worker({
        "type": JOB_COMPOSITE,
        "args": PackedStringArray(["--skip-models"]),
        "request": request,
        "status_label": "Fetching assets"
    })

func download_models_only() -> void:
    var request := _model_service.create_request()
    if request.is_empty():
        push_error("Default model configuration unavailable")
        return
    _start_worker({
        "type": JOB_MODEL,
        "request": request,
        "status_label": "Downloading model"
    })

func download_voices_only() -> void:
    _start_worker({
        "type": JOB_SCRIPT,
        "args": PackedStringArray(["--skip-models"]),
        "status_label": "Downloading voices"
    })

func clean_downloads() -> void:
    _start_worker({
        "type": JOB_SCRIPT,
        "args": PackedStringArray(["--clean"]),
        "status_label": "Cleaning assets"
    })

func _start_worker(job: Dictionary) -> void:
    if _is_running:
        push_warning("Download already in progress")
        return
    var job_type := job.get("type", JOB_SCRIPT)
    var needs_script := job_type in [JOB_SCRIPT, JOB_COMPOSITE]
    var script_path := ""
    if needs_script:
        if not FileAccess.file_exists(FETCH_SCRIPT):
            push_error("Download script missing: %s" % FETCH_SCRIPT)
            return
        script_path = ProjectSettings.globalize_path(FETCH_SCRIPT)
        job["script_path"] = script_path
    if _worker:
        _worker.wait_to_finish()
    _worker = Thread.new()
    _pending_job = job.duplicate(true)
    _is_running = true
    var status := job.get("status_label", "Running download")
    _set_running_state(true, status)
    _log_job(_pending_job)
    _worker.start(callable(self, "_thread_download"), script_path)

func _thread_download(script_path: String) -> void:
    var job := _pending_job.duplicate(true)
    var job_type := job.get("type", JOB_SCRIPT)
    var result := {}
    match job_type:
        JOB_SCRIPT:
            result = _execute_script_job(script_path, job)
        JOB_MODEL:
            result = _execute_model_job(job)
        JOB_COMPOSITE:
            result = _execute_composite_job(script_path, job)
        _:
            result = {"ok": false, "log": PackedStringArray(["Unknown job type: %s" % job_type]), "exit_code": -1}
    call_deferred("_on_download_finished", result)

func _execute_script_job(script_path: String, job: Dictionary) -> Dictionary:
    var args: PackedStringArray = job.get("args", PackedStringArray())
    var captured: Array = []
    var exit_code := OS.execute(script_path, args, captured, true, true)
    var lines := PackedStringArray()
    for entry in captured:
        lines.append(str(entry))
    return {
        "ok": exit_code == 0,
        "exit_code": exit_code,
        "log": lines
    }

func _execute_model_job(job: Dictionary) -> Dictionary:
    var request: Dictionary = job.get("request", {})
    var lines := PackedStringArray()
    if request.is_empty():
        lines.append("Model request missing")
        return {"ok": false, "log": lines, "exit_code": -1}
    if not ClassDB.class_exists("AgentRuntime"):
        lines.append("AgentRuntime class unavailable")
        return {"ok": false, "log": lines, "exit_code": -1}
    var runtime := AgentRuntime.get_singleton()
    if runtime == null:
        lines.append("AgentRuntime singleton unavailable")
        return {"ok": false, "log": lines, "exit_code": -1}
    var model_result: Dictionary = runtime.download_model(request)
    var model_log: PackedStringArray = model_result.get("log", PackedStringArray())
    lines.append_array(model_log)
    var ok := model_result.get("ok", false)
    if not ok and model_result.has("error"):
        lines.append("Error: %s" % model_result["error"])
    return {
        "ok": ok,
        "log": lines,
        "model": model_result,
        "exit_code": ok ? 0 : -1
    }

func _execute_composite_job(script_path: String, job: Dictionary) -> Dictionary:
    var combined := PackedStringArray()
    var script_result := _execute_script_job(script_path, job)
    combined.append_array(script_result.get("log", PackedStringArray()))
    if not script_result.get("ok", false):
        script_result["log"] = combined
        return script_result
    var model_job := {"request": job.get("request", {})}
    var model_result := _execute_model_job(model_job)
    combined.append_array(model_result.get("log", PackedStringArray()))
    return {
        "ok": model_result.get("ok", false),
        "log": combined,
        "model": model_result.get("model", {}),
        "exit_code": model_result.get("exit_code", -1)
    }

func _on_download_finished(result: Dictionary) -> void:
    var ok := result.get("ok", false)
    if output_log:
        var log_lines: PackedStringArray = result.get("log", PackedStringArray())
        for line in log_lines:
            output_log.append_text("%s\n" % line)
        output_log.append_text("\nResult: %s\n" % ("Success" if ok else "Failed"))
    _is_running = false
    if _worker:
        _worker.wait_to_finish()
        _worker = null
    _pending_job = {}
    _set_running_state(false, "Completed" if ok else "Failed")

func _reset_output() -> void:
    if output_log:
        output_log.clear()
        output_log.append_text("Local Agents Downloader\n")
        output_log.append_text("-------------------------\n")
        output_log.append_text("Downloads models, voices, and dependencies using llama.cpp helpers.\n\n")

func _log_job(job: Dictionary) -> void:
    _reset_output()
    if not output_log:
        return
    var job_type := job.get("type", JOB_SCRIPT)
    match job_type:
        JOB_MODEL:
            var request: Dictionary = job.get("request", {})
            output_log.append_text("AgentRuntime Model Download\n\n")
            output_log.append_text("Target: %s\n" % request.get("output_path", ""))
            output_log.append_text("Source: %s\n\n" % request.get("url", ""))
        JOB_COMPOSITE:
            var args: PackedStringArray = job.get("args", PackedStringArray())
            var arg_string := ""
            for arg in args:
                arg_string += " %s" % arg
            output_log.append_text("Dependency Script: %s%s\n" % [job.get("script_path", ""), arg_string])
            output_log.append_text("\nModel download will follow via AgentRuntime.\n\n")
        _:
            var args_default: PackedStringArray = job.get("args", PackedStringArray())
            var script_string := job.get("script_path", "")
            var combined := ""
            for arg in args_default:
                combined += " %s" % arg
            output_log.append_text("Running: %s%s\n\n" % [script_string, combined])

func _set_running_state(running: bool, label: String) -> void:
    if status_label:
        status_label.text = label
    if download_all_button:
        download_all_button.disabled = running
    if download_models_button:
        download_models_button.disabled = running
    if download_voices_button:
        download_voices_button.disabled = running
    if clean_button:
        clean_button.disabled = running
