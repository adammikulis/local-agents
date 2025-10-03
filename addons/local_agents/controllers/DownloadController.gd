@tool
extends Control
class_name LocalAgentsDownloadController

@export var output_log: RichTextLabel

@onready var status_label: Label = %StatusLabel
@onready var download_all_button: Button = %DownloadAllButton
@onready var download_models_button: Button = %DownloadModelsButton
@onready var download_voices_button: Button = %DownloadVoicesButton
@onready var clean_button: Button = %CleanButton
@onready var model_tree: Tree = %ModelTree
@onready var selection_info_label: Label = %SelectionInfo
@onready var refresh_button: Button = %RefreshButton

const FETCH_SCRIPT := "res://addons/local_agents/gdextensions/localagents/scripts/fetch_dependencies.sh"
const MODEL_SERVICE := preload("res://addons/local_agents/controllers/ModelDownloadService.gd")

const JOB_SCRIPT := "script"
const JOB_MODEL := "model"
const JOB_COMPOSITE := "composite"

var _worker: Thread
var _is_running := false
var _pending_job: Dictionary = {}
var _model_service := MODEL_SERVICE.new()
var _selected_model_id := ""

func _ready() -> void:
    _reset_output()
    _populate_model_tree()
    _set_running_state(false, "Idle")

func _exit_tree() -> void:
    if _worker:
        _worker.wait_to_finish()
        _worker = null

func download_all() -> void:
    var request := _model_service.create_request({}, _selected_model_id)
    if request.is_empty():
        push_error("Default model configuration unavailable")
        return
    var status := "Fetching assets"
    if request.has("label"):
        status = "Fetching assets & %s" % request["label"]
    _start_worker({
        "type": JOB_COMPOSITE,
        "args": PackedStringArray(["--skip-models"]),
        "request": request,
        "status_label": status
    })

func download_models_only() -> void:
    var request := _model_service.create_request({}, _selected_model_id)
    if request.is_empty():
        push_error("Default model configuration unavailable")
        return
    var status := "Downloading model"
    if request.has("label"):
        status = "Downloading %s" % request["label"]
    _start_worker({
        "type": JOB_MODEL,
        "request": request,
        "status_label": status
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

func refresh_models() -> void:
    if _is_running:
        push_warning("Download already in progress")
        return
    _model_service.reload_catalog()
    _populate_model_tree()
    _set_running_state(false, "Catalog refreshed")

func _start_worker(job: Dictionary) -> void:
    if _is_running:
        push_warning("Download already in progress")
        return
    var job_type := job.get("type", JOB_SCRIPT)
    var needs_script: bool = job_type in [JOB_SCRIPT, JOB_COMPOSITE]
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
    _worker.start(Callable(self, "_thread_download").bind(script_path))

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
    if not Engine.has_singleton("AgentRuntime"):
        lines.append("AgentRuntime singleton unavailable")
        return {"ok": false, "log": lines, "exit_code": -1}
    var runtime: Object = Engine.get_singleton("AgentRuntime")
    if runtime == null:
        lines.append("AgentRuntime singleton unavailable")
        return {"ok": false, "log": lines, "exit_code": -1}
    if not runtime.has_method("download_model"):
        lines.append("AgentRuntime missing download_model")
        return {"ok": false, "log": lines, "exit_code": -1}
    var model_result: Dictionary = runtime.call("download_model", request)
    var model_log: PackedStringArray = model_result.get("log", PackedStringArray())
    lines.append_array(model_log)
    var ok := model_result.get("ok", false)
    if not ok and model_result.has("error"):
        lines.append("Error: %s" % model_result["error"])
    var exit_code := 0
    if not ok:
        exit_code = -1
    return {
        "ok": ok,
        "log": lines,
        "model": model_result,
        "exit_code": exit_code
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

func _populate_model_tree() -> void:
    if not model_tree:
        return
    model_tree.clear()
    _selected_model_id = ""
    _update_selection_info({})
    model_tree.set_column_title(0, "Model")
    model_tree.set_column_title(1, "Params")
    model_tree.set_column_title(2, "Size")
    model_tree.set_column_title(3, "Updated")
    var root := model_tree.create_item()
    var families := _model_service.list_families()
    var default_model := _model_service.get_default_model()
    var default_id := default_model.get("id", "")
    var selection_set := false
    var first_model_item: TreeItem = null
    for family in families:
        var family_item := model_tree.create_item(root)
        family_item.set_text(0, family.get("label", ""))
        family_item.set_metadata(0, "")
        family_item.collapsed = false
        for model in family.get("models", []):
            var item := model_tree.create_item(family_item)
            item.set_text(0, model.get("label", ""))
            item.set_text(1, model.get("parameters", ""))
            item.set_text(2, model.get("size_pretty", ""))
            item.set_text(3, _format_updated(model.get("updated_timestamp", 0)))
            item.set_metadata(0, model.get("id", ""))
            item.set_tooltip_text(0, _build_model_tooltip(model))
            if first_model_item == null:
                first_model_item = item
            if not selection_set and (model.get("recommended", false) or model.get("id", "") == default_id):
                model_tree.select_item(item, 0)
                _apply_model_selection(model)
                selection_set = true
    if not selection_set and first_model_item:
        model_tree.select_item(first_model_item, 0)
        var meta := first_model_item.get_metadata(0)
        if typeof(meta) == TYPE_STRING and String(meta) != "":
            var fallback_model := _model_service.find_model(String(meta))
            _apply_model_selection(fallback_model)

func _apply_model_selection(model: Dictionary) -> void:
    _selected_model_id = model.get("id", "")
    _update_selection_info(model)

func _update_selection_info(model: Dictionary) -> void:
    if not selection_info_label:
        return
    if model.is_empty():
        selection_info_label.text = "Select a model to view download details"
        return
    var parts: Array = []
    parts.append("Selected: %s" % model.get("label", ""))
    var params := model.get("parameters", "")
    var size := model.get("size_pretty", "")
    var updated := _format_updated(model.get("updated_timestamp", 0))
    var meta_parts: Array = []
    if params != "":
        meta_parts.append(params)
    if size != "":
        meta_parts.append(size)
    if updated != "Unknown":
        meta_parts.append("Updated %s" % updated)
    if not meta_parts.is_empty():
        parts.append(" • ".join(meta_parts))
    var repo_url := model.get("repo_url", "")
    if repo_url != "":
        parts.append("Source: %s" % repo_url)
    selection_info_label.text = "\n".join(parts)

func _format_updated(timestamp: int) -> String:
    if timestamp <= 0:
        return "Unknown"
    var dt := Time.get_datetime_string_from_unix_time(timestamp)
    if dt.length() >= 10:
        return dt.substr(0, 10)
    return dt

func _build_model_tooltip(model: Dictionary) -> String:
    var lines: Array = []
    lines.append(model.get("label", ""))
    var params := model.get("parameters", "")
    var quant := model.get("quantization", "")
    var size := model.get("size_pretty", "")
    var updated := model.get("updated_at", "")
    if params != "":
        lines.append("Parameters: %s" % params)
    if quant != "":
        lines.append("Quantization: %s" % quant)
    if size != "":
        lines.append("Size: %s" % size)
    if updated != "":
        lines.append("Updated: %s" % updated)
    var repo_url := model.get("repo_url", "")
    if repo_url != "":
        lines.append("Source: %s" % repo_url)
    return "\n".join(lines)

func _on_model_tree_item_selected() -> void:
    if not model_tree:
        return
    var item := model_tree.get_selected()
    if item == null:
        _selected_model_id = ""
        _update_selection_info({})
        return
    var model_id_variant := item.get_metadata(0)
    if typeof(model_id_variant) == TYPE_STRING and String(model_id_variant) != "":
        var model := _model_service.find_model(String(model_id_variant))
        _apply_model_selection(model)
    else:
        _selected_model_id = ""
        _update_selection_info({})

func _on_model_tree_item_activated() -> void:
    if not model_tree:
        return
    var item := model_tree.get_selected()
    if item == null:
        return
    var model_id_variant := item.get_metadata(0)
    if typeof(model_id_variant) == TYPE_STRING and String(model_id_variant) != "":
        download_models_only()

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
    if refresh_button:
        refresh_button.disabled = running
    if model_tree:
        model_tree.disabled = running
