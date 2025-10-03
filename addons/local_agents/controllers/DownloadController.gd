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

var _worker: Thread
var _is_running := false
var _pending_args: PackedStringArray = []

func _ready() -> void:
    _reset_output()
    _set_running_state(false, "Idle")

func _exit_tree() -> void:
    if _worker:
        _worker.wait_to_finish()
        _worker = null

func download_all() -> void:
    _start_worker(PackedStringArray())

func download_models_only() -> void:
    _start_worker(PackedStringArray(["--skip-voices"]))

func download_voices_only() -> void:
    _start_worker(PackedStringArray(["--skip-models"]))

func clean_downloads() -> void:
    _start_worker(PackedStringArray(["--clean"]))

func _start_worker(args: PackedStringArray) -> void:
    if _is_running:
        push_warning("Download already in progress")
        return
    if not FileAccess.file_exists(FETCH_SCRIPT):
        push_error("Download script missing: %s" % FETCH_SCRIPT)
        return
    var script_path := ProjectSettings.globalize_path(FETCH_SCRIPT)
    if _worker:
        _worker.wait_to_finish()
    _worker = Thread.new()
    _pending_args = PackedStringArray()
    for arg in args:
        _pending_args.append(arg)
    _is_running = true
    _set_running_state(true, "Running download")
    _log_command(script_path, args)
    _worker.start(callable(self, "_thread_download"), script_path)

func _thread_download(script_path: String) -> void:
    var output: Array = []
    var args := PackedStringArray()
    for arg in _pending_args:
        args.append(arg)
    var code := OS.execute(script_path, args, output, true, true)
    call_deferred("_on_download_finished", code, output)

func _on_download_finished(exit_code: int, output: Array) -> void:
    if output_log:
        for line in output:
            output_log.append_text("%s\n" % line)
        var result_text := "Success" if exit_code == 0 else "Failed (%d)" % exit_code
        output_log.append_text("\nResult: %s\n" % result_text)
    _is_running = false
    if _worker:
        _worker.wait_to_finish()
        _worker = null
    var final_status := "Completed" if exit_code == 0 else "Failed (%d)" % exit_code
    _set_running_state(false, final_status)

func _reset_output() -> void:
    if output_log:
        output_log.clear()
        output_log.append_text("Local Agents Downloader\n")
        output_log.append_text("-------------------------\n")
        output_log.append_text("Downloads models, voices, and dependencies using llama.cpp helpers.\n\n")

func _log_command(script_path: String, args: PackedStringArray) -> void:
    _reset_output()
    if output_log:
        var arg_string := ""
        for arg in args:
            arg_string += " %s" % arg
        output_log.append_text("Running: %s%s\n\n" % [script_path, arg_string])

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
