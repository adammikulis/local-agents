@tool
extends Control
class_name LADownloadController

## The editor Downloads tab: pick a model from the shipped catalog, fetch it, and watch the log.
##
## There is exactly one downloader in this addon now. This tab used to route models through a thin
## `api/` wrapper over the `AgentRuntime` native singleton, so downloading a model required the
## native library, which is the very thing you download a model in order to use.
## It now drives `LAModelDownloadManager` (pure GDScript, HTTPRequest, streams to a `.part`
## file and promotes it only after the size verifies), the same downloader the in-game panel uses.
## Nothing on the model path needs the native binary any more.
##
## The worker Thread survives only for the shell script job (voices / build dependencies via
## fetch_dependencies.sh). The model path is signal-driven and needs no thread at all.
##
## (Explicit types only. Project rule: no ':=' inferred typing.)

const FETCH_SCRIPT: String = "res://addons/local_agents/gdextensions/localagents/scripts/fetch_dependencies.sh"
const MODEL_SERVICE: GDScript = preload("res://addons/local_agents/controllers/ModelDownloadService.gd")
const DOWNLOAD_MANAGER: GDScript = preload("res://addons/local_agents/ui/ModelDownloadManager.gd")

@export_group("Wiring")
## RichTextLabel that receives the download transcript (script output, URLs, results). Leave unset
## to run the tab silently.
@export var output_log: RichTextLabel

# Resolved by scene path, not by `%`. DownloadTab.tscn sets unique_name_in_owner on StatusLabel and
# SelectionInfo only, so the other six lookups returned null and pushed "Node not found" at load:
# the buttons never disabled during a download, and the model tree was never populated.
@onready var status_label: Label = $VBoxContainer/StatusLabel
@onready var download_all_button: Button = $VBoxContainer/ButtonRow/DownloadAllButton
@onready var download_models_button: Button = $VBoxContainer/ButtonRow/DownloadModelsButton
@onready var download_voices_button: Button = $VBoxContainer/ButtonRow/DownloadVoicesButton
@onready var clean_button: Button = $VBoxContainer/ButtonRow/CleanButton
@onready var model_tree: Tree = $VBoxContainer/ModelPanel/ModelTree
@onready var selection_info_label: Label = $VBoxContainer/SelectionInfo
@onready var refresh_button: Button = $VBoxContainer/ModelHeader/RefreshButton

var _model_service: LocalAgentModelDownloadService = MODEL_SERVICE.new()
var _downloader: LAModelDownloadManager = null
var _selected_model_id: String = ""

# Shell-script job state (voices / dependencies). The model job carries none of this.
var _worker: Thread = null
var _script_running: bool = false
var _pending_args: PackedStringArray = PackedStringArray()
# Model queued to start once the script job succeeds ("Download Defaults" = script, then model).
var _queued_model_id: String = ""
var _active_model_label: String = ""

func _ready() -> void:
    _reset_output()
    _ensure_downloader()
    _populate_model_tree()
    _set_running_state(false, "Idle")

func _exit_tree() -> void:
    if _worker:
        _worker.wait_to_finish()
        _worker = null

# -- Public actions (wired from DownloadTab.tscn) ------------------------------

## Dependencies + voices first, then the selected (or recommended) model.
func download_all() -> void:
    var model_id: String = _resolve_model_id()
    if model_id == "":
        push_error("Default model configuration unavailable")
        return
    _queued_model_id = model_id
    _start_script_job(PackedStringArray(["--skip-models"]), "Fetching assets")

func download_models_only() -> void:
    var model_id: String = _resolve_model_id()
    if model_id == "":
        push_error("Default model configuration unavailable")
        return
    _queued_model_id = ""
    _start_model_job(model_id)

func download_voices_only() -> void:
    _queued_model_id = ""
    _start_script_job(PackedStringArray(["--skip-models"]), "Downloading voices")

func clean_downloads() -> void:
    _queued_model_id = ""
    _start_script_job(PackedStringArray(["--clean"]), "Cleaning assets")

func refresh_models() -> void:
    if _is_busy():
        push_warning("Download already in progress")
        return
    _model_service.reload_catalog()
    _populate_model_tree()
    _set_running_state(false, "Catalog refreshed")

# -- Model download (LAModelDownloadManager) ---------------------------

func _ensure_downloader() -> void:
    if _downloader != null:
        return
    _downloader = DOWNLOAD_MANAGER.new()
    _downloader.name = "EditorModelDownloader"
    add_child(_downloader)
    _downloader.download_started.connect(_on_model_download_started)
    _downloader.download_progress.connect(_on_model_download_progress)
    _downloader.download_finished.connect(_on_model_download_finished)

func _resolve_model_id() -> String:
    if _selected_model_id != "":
        return _selected_model_id
    var default_model: Dictionary = _model_service.get_default_model()
    return String(default_model.get("id", ""))

func _start_model_job(model_id: String) -> void:
    if _is_busy():
        push_warning("Download already in progress")
        return
    _ensure_downloader()
    if _downloader == null:
        push_error("Model downloader unavailable")
        return
    var model: Dictionary = _model_service.find_model(model_id)
    var label: String = String(model.get("label", model_id))
    var installed: String = _downloader.installed_path(model_id)
    if installed != "":
        _log("%s is already installed at %s" % [label, installed])
        _set_running_state(false, "%s already installed" % label)
        return

    _active_model_label = label
    _reset_output()
    _log("Downloading %s" % label)
    var download_url: String = String(model.get("download_url", ""))
    if download_url != "":
        _log("Source: %s" % download_url)
    var size_bytes: int = int(model.get("size_bytes", 0))
    if size_bytes > 0:
        _log("Size: %s" % LAModelDownloadManager.format_bytes(size_bytes))
    _log("")
    _set_running_state(true, "Downloading %s" % label)

    if not _downloader.start_download(model_id):
        _log("Could not start the download (busy, unknown model id, or no network).")
        _set_running_state(false, "Failed to start %s" % label)
        _active_model_label = ""

func _on_model_download_started(_model_id: String, total_bytes: int) -> void:
    var total_text: String = "unknown size"
    if total_bytes > 0:
        total_text = LAModelDownloadManager.format_bytes(total_bytes)
    _set_running_state(true, "%s, starting (%s)" % [_active_model_label, total_text])

func _on_model_download_progress(_model_id: String, received_bytes: int, total_bytes: int, speed_bytes_per_sec: float, eta_seconds: float) -> void:
    if status_label == null:
        return
    var percent: float = 0.0
    if total_bytes > 0:
        percent = clampf(float(received_bytes) / float(total_bytes) * 100.0, 0.0, 100.0)
    var received_text: String = LAModelDownloadManager.format_bytes(received_bytes)
    var total_text: String = "?"
    if total_bytes > 0:
        total_text = LAModelDownloadManager.format_bytes(total_bytes)
    status_label.text = "%s %.1f%% (%s / %s) · %s · %s" % [
        _active_model_label,
        percent,
        received_text,
        total_text,
        LAModelDownloadManager.format_speed(speed_bytes_per_sec),
        LAModelDownloadManager.format_eta(eta_seconds),
    ]

func _on_model_download_finished(_model_id: String, ok: bool, path: String, error: String) -> void:
    var label: String = _active_model_label
    if label == "":
        label = "model"
    if ok:
        _log("Downloaded: %s" % path)
        _set_running_state(false, "Downloaded %s" % label)
    else:
        _log("Download failed: %s" % error)
        _set_running_state(false, "Failed %s (%s)" % [label, error])
    _active_model_label = ""

# -- Shell script job (voices / build dependencies) ----------------------------

func _start_script_job(args: PackedStringArray, status: String) -> void:
    if _is_busy():
        push_warning("Download already in progress")
        return
    if not FileAccess.file_exists(FETCH_SCRIPT):
        push_error("Download script missing: %s" % FETCH_SCRIPT)
        _queued_model_id = ""
        return
    var script_path: String = ProjectSettings.globalize_path(FETCH_SCRIPT)
    if _worker:
        _worker.wait_to_finish()
    _worker = Thread.new()
    _pending_args = args
    _script_running = true
    _reset_output()
    _log("Running: %s %s" % [script_path, " ".join(args)])
    if _queued_model_id != "":
        _log("A model download will follow once the script finishes.")
    _log("")
    _set_running_state(true, status)
    _worker.start(Callable(self, "_thread_script_job").bind(script_path))

func _thread_script_job(script_path: String) -> void:
    var captured: Array = []
    var exit_code: int = OS.execute(script_path, _pending_args, captured, true, true)
    var lines: PackedStringArray = PackedStringArray()
    for entry in captured:
        lines.append(str(entry))
    call_deferred("_on_script_job_finished", exit_code, lines)

func _on_script_job_finished(exit_code: int, lines: PackedStringArray) -> void:
    _script_running = false
    if _worker:
        _worker.wait_to_finish()
        _worker = null
    for line in lines:
        _log(line)
    var ok: bool = exit_code == 0
    _log("")
    _log("Script result: %s (exit %d)" % ["Success" if ok else "Failed", exit_code])
    if ok and _queued_model_id != "":
        var next_id: String = _queued_model_id
        _queued_model_id = ""
        _start_model_job(next_id)
        return
    _queued_model_id = ""
    _set_running_state(false, "Completed" if ok else "Failed")

func _is_busy() -> bool:
    if _script_running:
        return true
    return _downloader != null and _downloader.is_downloading()

# -- Log -----------------------------------------------------------------------

func _log(line: String) -> void:
    if output_log:
        output_log.append_text("%s\n" % line)

func _reset_output() -> void:
    if output_log:
        output_log.clear()
        output_log.append_text("Local Agents Downloader\n")
        output_log.append_text("-------------------------\n")
        output_log.append_text("Models stream straight to user://local_agents/models; voices and build dependencies use fetch_dependencies.sh.\n\n")

# -- Model catalog tree --------------------------------------------------------

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
    var root: TreeItem = model_tree.create_item()
    var families: Array = _model_service.list_families()
    var default_model: Dictionary = _model_service.get_default_model()
    var default_id: String = String(default_model.get("id", ""))
    var selection_set: bool = false
    var first_model_item: TreeItem = null
    for family_variant in families:
        var family: Dictionary = family_variant
        var family_item: TreeItem = model_tree.create_item(root)
        family_item.set_text(0, String(family.get("label", "")))
        family_item.set_metadata(0, "")
        family_item.collapsed = false
        for model_variant in family.get("models", []):
            var model: Dictionary = model_variant
            var item: TreeItem = model_tree.create_item(family_item)
            item.set_text(0, String(model.get("label", "")))
            item.set_text(1, String(model.get("parameters", "")))
            item.set_text(2, String(model.get("size_pretty", "")))
            item.set_text(3, _format_updated(int(model.get("updated_timestamp", 0))))
            item.set_metadata(0, String(model.get("id", "")))
            item.set_tooltip_text(0, _build_model_tooltip(model))
            if first_model_item == null:
                first_model_item = item
            if not selection_set and (bool(model.get("recommended", false)) or String(model.get("id", "")) == default_id):
                model_tree.select_item(item, 0)
                _apply_model_selection(model)
                selection_set = true
    if not selection_set and first_model_item:
        model_tree.select_item(first_model_item, 0)
        var meta: Variant = first_model_item.get_metadata(0)
        if typeof(meta) == TYPE_STRING and String(meta) != "":
            var fallback_model: Dictionary = _model_service.find_model(String(meta))
            _apply_model_selection(fallback_model)

func _apply_model_selection(model: Dictionary) -> void:
    _selected_model_id = String(model.get("id", ""))
    _update_selection_info(model)

func _update_selection_info(model: Dictionary) -> void:
    if not selection_info_label:
        return
    if model.is_empty():
        selection_info_label.text = "Select a model to view download details"
        return
    var parts: Array[String] = []
    parts.append("Selected: %s" % String(model.get("label", "")))
    var params: String = String(model.get("parameters", ""))
    var size: String = String(model.get("size_pretty", ""))
    var updated: String = _format_updated(int(model.get("updated_timestamp", 0)))
    var meta_parts: Array[String] = []
    if params != "":
        meta_parts.append(params)
    if size != "":
        meta_parts.append(size)
    if updated != "Unknown":
        meta_parts.append("Updated %s" % updated)
    if not meta_parts.is_empty():
        parts.append(" • ".join(meta_parts))
    var repo_url: String = String(model.get("repo_url", ""))
    if repo_url != "":
        parts.append("Source: %s" % repo_url)
    selection_info_label.text = "\n".join(parts)

func _format_updated(timestamp: int) -> String:
    if timestamp <= 0:
        return "Unknown"
    var dt: String = Time.get_datetime_string_from_unix_time(timestamp)
    if dt.length() >= 10:
        return dt.substr(0, 10)
    return dt

func _build_model_tooltip(model: Dictionary) -> String:
    var lines: Array[String] = []
    lines.append(String(model.get("label", "")))
    var params: String = String(model.get("parameters", ""))
    var quant: String = String(model.get("quantization", ""))
    var size: String = String(model.get("size_pretty", ""))
    var updated: String = String(model.get("updated_at", ""))
    if params != "":
        lines.append("Parameters: %s" % params)
    if quant != "":
        lines.append("Quantization: %s" % quant)
    if size != "":
        lines.append("Size: %s" % size)
    if updated != "":
        lines.append("Updated: %s" % updated)
    var repo_url: String = String(model.get("repo_url", ""))
    if repo_url != "":
        lines.append("Source: %s" % repo_url)
    return "\n".join(lines)

func _on_model_tree_item_selected() -> void:
    if not model_tree:
        return
    var item: TreeItem = model_tree.get_selected()
    if item == null:
        _selected_model_id = ""
        _update_selection_info({})
        return
    var model_id_variant: Variant = item.get_metadata(0)
    if typeof(model_id_variant) == TYPE_STRING and String(model_id_variant) != "":
        var model: Dictionary = _model_service.find_model(String(model_id_variant))
        _apply_model_selection(model)
    else:
        _selected_model_id = ""
        _update_selection_info({})

func _on_model_tree_item_activated() -> void:
    if not model_tree:
        return
    var item: TreeItem = model_tree.get_selected()
    if item == null:
        return
    var model_id_variant: Variant = item.get_metadata(0)
    if typeof(model_id_variant) == TYPE_STRING and String(model_id_variant) != "":
        download_models_only()

# -- Button state --------------------------------------------------------------

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
        model_tree.mouse_filter = Control.MOUSE_FILTER_IGNORE if running else Control.MOUSE_FILTER_STOP
