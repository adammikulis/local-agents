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
const DOWNLOAD_CLIENT := preload("res://addons/local_agents/api/DownloadClient.gd")

const JOB_SCRIPT := "script"
const JOB_MODEL := "model"
const JOB_COMPOSITE := "composite"

var _worker: Thread
var _is_running := false
var _pending_job: Dictionary = {}
var _model_service := MODEL_SERVICE.new()
var _download_client := DOWNLOAD_CLIENT
var _selected_model_id := ""
var _runtime: Object = null
var _runtime_connected := false
var _runtime_log_streaming := false
var _active_download_path := ""
var _active_download_dir := ""
var _active_download_label := ""
var _active_download_progress := 0.0
var _active_download_received := 0
var _active_download_total := 0

func _ready() -> void:
    _reset_output()
    _populate_model_tree()
    _set_running_state(false, "Idle")
    _connect_runtime_signals()

func _exit_tree() -> void:
    if _worker:
        _worker.wait_to_finish()
        _worker = null
    _disconnect_runtime_signals()

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
            _clear_runtime_tracking()
            return
        script_path = ProjectSettings.globalize_path(FETCH_SCRIPT)
        job["script_path"] = script_path
    if _worker:
        _worker.wait_to_finish()
    _worker = Thread.new()
    if job_type == JOB_MODEL or job_type == JOB_COMPOSITE:
        _start_tracking_request(job.get("request", {}))
    else:
        _clear_runtime_tracking()
    _pending_job = job.duplicate(true)
    _is_running = true
    var status := job.get("status_label", "Running download")
    _set_running_state(true, status)
    _log_job(_pending_job)
    _worker.start(Callable(self, "_thread_download").bind(script_path))

func _connect_runtime_signals() -> void:
    if _runtime_connected:
        return
    if not Engine.has_singleton("AgentRuntime"):
        return
    var runtime := Engine.get_singleton("AgentRuntime")
    if runtime == null:
        return
    var connected := false
    if runtime.has_signal("download_started") and not runtime.is_connected("download_started", Callable(self, "_on_runtime_download_started")):
        runtime.connect("download_started", Callable(self, "_on_runtime_download_started"))
        connected = true
    if runtime.has_signal("download_progress") and not runtime.is_connected("download_progress", Callable(self, "_on_runtime_download_progress")):
        runtime.connect("download_progress", Callable(self, "_on_runtime_download_progress"))
        connected = true
    if runtime.has_signal("download_log") and not runtime.is_connected("download_log", Callable(self, "_on_runtime_download_log")):
        runtime.connect("download_log", Callable(self, "_on_runtime_download_log"))
        connected = true
    if runtime.has_signal("download_finished") and not runtime.is_connected("download_finished", Callable(self, "_on_runtime_download_finished")):
        runtime.connect("download_finished", Callable(self, "_on_runtime_download_finished"))
        connected = true
    if connected:
        _runtime = runtime
        _runtime_connected = true

func _disconnect_runtime_signals() -> void:
    if not _runtime_connected:
        return
    if _runtime == null:
        _runtime_connected = false
        return
    if _runtime.is_connected("download_started", Callable(self, "_on_runtime_download_started")):
        _runtime.disconnect("download_started", Callable(self, "_on_runtime_download_started"))
    if _runtime.is_connected("download_progress", Callable(self, "_on_runtime_download_progress")):
        _runtime.disconnect("download_progress", Callable(self, "_on_runtime_download_progress"))
    if _runtime.is_connected("download_log", Callable(self, "_on_runtime_download_log")):
        _runtime.disconnect("download_log", Callable(self, "_on_runtime_download_log"))
    if _runtime.is_connected("download_finished", Callable(self, "_on_runtime_download_finished")):
        _runtime.disconnect("download_finished", Callable(self, "_on_runtime_download_finished"))
    _runtime = null
    _runtime_connected = false

func _start_tracking_request(request: Dictionary) -> void:
    _connect_runtime_signals()
    _runtime_log_streaming = _runtime_connected
    if request.is_empty():
        _clear_runtime_tracking()
        return
    var output_path_variant := request.get("output_path", "")
    _active_download_path = String(output_path_variant)
    _active_download_dir = _active_download_path.get_base_dir()
    _active_download_label = String(request.get("label", ""))
    _active_download_progress = 0.0
    _active_download_received = 0
    _active_download_total = 0

func _clear_runtime_tracking() -> void:
    _active_download_path = ""
    _active_download_dir = ""
    _active_download_label = ""
    _active_download_progress = 0.0
    _active_download_received = 0
    _active_download_total = 0
    _runtime_log_streaming = false

func _is_tracking_path(path: String) -> bool:
    if _active_download_path.is_empty():
        return false
    if path == _active_download_path:
        return true
    if _active_download_dir != "" and path.begins_with(_active_download_dir):
        return true
    return false

func _on_runtime_download_started(label: String, path: String) -> void:
    call_deferred("_handle_runtime_started", label, path)

func _handle_runtime_started(label: String, path: String) -> void:
    if not _is_tracking_path(path):
        return
    _active_download_label = label
    _active_download_progress = 0.0
    _active_download_received = 0
    _active_download_total = 0
    _refresh_runtime_status_label()

func _on_runtime_download_progress(label: String, progress: float, received_bytes: int, total_bytes: int, path: String) -> void:
    call_deferred("_update_runtime_progress", label, progress, received_bytes, total_bytes, path)

func _update_runtime_progress(label: String, progress: float, received_bytes: int, total_bytes: int, path: String) -> void:
    if not _is_tracking_path(path):
        return
    if label != "":
        _active_download_label = label
    _active_download_progress = progress
    _active_download_received = received_bytes
    _active_download_total = total_bytes
    _refresh_runtime_status_label()

func _on_runtime_download_log(line: String, path: String) -> void:
    call_deferred("_append_runtime_log_line", line, path)

func _append_runtime_log_line(line: String, path: String) -> void:
    if not _is_tracking_path(path):
        return
    if output_log:
        output_log.append_text("%s\n" % line)

func _on_runtime_download_finished(ok: bool, error: String, path: String) -> void:
    call_deferred("_handle_runtime_finished", ok, error, path)

func _handle_runtime_finished(ok: bool, error: String, path: String) -> void:
    if not _is_tracking_path(path):
        return
    if ok:
        _active_download_progress = 1.0
        _active_download_received = max(_active_download_received, _active_download_total)
    _refresh_runtime_status_label()

func _refresh_runtime_status_label() -> void:
    if not status_label:
        return
    var label := _active_download_label
    if label == "":
        label = "Downloading model"
    var percent := clamp(_active_download_progress * 100.0, 0.0, 100.0)
    if _active_download_total > 0:
        status_label.text = "%s %.1f%% (%s / %s)" % [label, percent, _format_bytes(_active_download_received), _format_bytes(_active_download_total)]
    elif _active_download_received > 0:
        status_label.text = "%s %.1f%% (%s)" % [label, percent, _format_bytes(_active_download_received)]
    else:
        status_label.text = "%s %.1f%%" % [label, percent]

func _format_bytes(amount: int) -> String:
    if amount <= 0:
        return "0 B"
    var units := ["B", "KB", "MB", "GB", "TB"]
    var size := float(amount)
    var index := 0
    while size >= 1024.0 and index < units.size() - 1:
        size /= 1024.0
        index += 1
    if index == 0:
        return "%d %s" % [int(size), units[index]]
    return "%.2f %s" % [size, units[index]]

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
    var model_result: Dictionary = _download_client.download_request(request)
    var model_log: PackedStringArray = model_result.get("log", PackedStringArray())
    if not _runtime_log_streaming:
        lines.append_array(model_log)
    var ok := model_result.get("ok", false)
    if not ok and model_result.has("error"):
        lines.append("Error: %s" % model_result["error"])
    elif ok and model_result.has("sha256"):
        lines.append("SHA256: %s" % model_result["sha256"])
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
    if not _runtime_log_streaming:
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
    var final_message := "Completed" if ok else "Failed"
    if _active_download_label != "":
        final_message = "%s %s" % [("Downloaded" if ok else "Failed"), _active_download_label]
    _set_running_state(false, final_message)
    _clear_runtime_tracking()

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
            var hf_repo := String(request.get("hf_repo", ""))
            if hf_repo != "":
                output_log.append_text("HF Repo: %s\n" % hf_repo)
            var hf_file := String(request.get("hf_file", ""))
            if hf_file != "":
                output_log.append_text("HF File: %s\n" % hf_file)
            var hf_tag := String(request.get("hf_tag", ""))
            if hf_tag != "":
                output_log.append_text("HF Tag: %s\n" % hf_tag)
            var sha := String(request.get("sha256", ""))
            if sha != "":
                output_log.append_text("Expected SHA256: %s\n" % sha)
            if hf_repo != "" or hf_file != "" or hf_tag != "":
                output_log.append_text("\n")
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
