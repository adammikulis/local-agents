extends Control
class_name LocalAgentsModelDownloadPanel

# Runtime (in-game) model download panel.
#
# Shows a curated shortlist of ungated GGUF models, each with its size shown up front and a Download
# button (or an "Installed" badge if the file is already present under user://local_agents/models).
# Downloading swaps the row into a live progress bar with "420 MB / 1.1 GB", an EMA-smoothed speed,
# an ETA ("~2m left") and a Cancel button. All fetching is async via LocalAgentsModelDownloadManager.
#
# Public API (for a main menu / "no model yet" prompt to invoke later — not wired here):
#   open()                       -> show the panel and refresh installed states
#   close()                      -> hide the panel
#   is_model_installed(model_id) -> bool
#   model_installed(model_id, path)  [signal] re-emitted when a download completes
#
# Self-harness: launched standalone it honors `-- --downloader-selftest` (prints
# DOWNLOADER_SELFTEST={...} then quits) and `-- --shoot=<png> [--shoot-frames=N]` (off-screen
# screenshot). `--demo-installed=<id>` forces a row into the Installed state for a screenshot.

const ModelDownloadManager: GDScript = preload("res://addons/local_agents/ui/ModelDownloadManager.gd")

signal model_installed(model_id: String, path: String)

@onready var _rows_box: VBoxContainer = %RowsBox
@onready var _status_label: Label = %StatusLabel
@onready var _title_label: Label = %TitleLabel

var _manager: LocalAgentsModelDownloadManager = null
var _rows: Dictionary = {}   # model_id -> Dictionary of that row's controls

# --- Self-harness state ---
var _shoot_path: String = ""
var _shoot_frames: int = 12
var _shoot_counter: int = 0
var _demo_installed_id: String = ""

func _ready() -> void:
	_parse_cmdline()

	if _run_selftest_if_requested():
		return

	_manager = ModelDownloadManager.new()
	_manager.name = "ModelDownloadManager"
	add_child(_manager)
	_manager.download_started.connect(_on_download_started)
	_manager.download_progress.connect(_on_download_progress)
	_manager.download_finished.connect(_on_download_finished)
	_manager.model_installed.connect(_on_model_installed)

	_build_rows()
	_refresh_all_rows()

	if _shoot_path != "" or OS.has_environment("LA_OFFSCREEN"):
		DisplayServer.window_set_position(Vector2i(-8000, -8000))
	if _shoot_path != "":
		set_process(true)

func _run_selftest_if_requested() -> bool:
	for arg: String in OS.get_cmdline_user_args():
		if arg == "--downloader-selftest":
			var report: Dictionary = ModelDownloadManager.run_selftest()
			print("DOWNLOADER_SELFTEST=%s" % JSON.stringify(report))
			get_tree().quit(0 if bool(report.get("ok", false)) else 1)
			return true
	return false

func _parse_cmdline() -> void:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--shoot="):
			_shoot_path = arg.substr("--shoot=".length())
		elif arg.begins_with("--shoot-frames="):
			_shoot_frames = int(arg.substr("--shoot-frames=".length()))
		elif arg.begins_with("--demo-installed="):
			_demo_installed_id = arg.substr("--demo-installed=".length())

func _process(_delta: float) -> void:
	if _shoot_path == "":
		return
	_shoot_counter += 1
	if _shoot_counter == _shoot_frames:
		_capture_screenshot(_shoot_path)
		get_tree().quit(0)

func _capture_screenshot(path: String) -> void:
	var img: Image = get_viewport().get_texture().get_image()
	img.save_png(path)
	print("SHOT_SAVED=%s size=%dx%d" % [path, img.get_width(), img.get_height()])

# -- Public API ---------------------------------------------------------------

func open() -> void:
	visible = true
	_refresh_all_rows()

func close() -> void:
	visible = false

func is_model_installed(model_id: String) -> bool:
	if _manager == null:
		return false
	return _manager.is_model_installed(model_id)

# -- Row construction ---------------------------------------------------------

func _build_rows() -> void:
	if _rows_box == null:
		return
	for child: Node in _rows_box.get_children():
		child.queue_free()
	_rows.clear()

	var catalog: Array = _manager.catalog()
	if catalog.is_empty():
		var empty: Label = Label.new()
		empty.text = "No models available in the catalog."
		_rows_box.add_child(empty)
		return

	for model: Dictionary in catalog:
		_rows_box.add_child(_make_row(model))

func _make_row(model: Dictionary) -> Control:
	var model_id: String = String(model.get("id", ""))

	var panel: PanelContainer = PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var margin: MarginContainer = MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_bottom", 8)
	panel.add_child(margin)

	var vbox: VBoxContainer = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	margin.add_child(vbox)

	# Top line: model name/size on the left, action area on the right.
	var top: HBoxContainer = HBoxContainer.new()
	top.add_theme_constant_override("separation", 12)
	vbox.add_child(top)

	var name_label: Label = Label.new()
	name_label.text = String(model.get("display", model_id))
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	top.add_child(name_label)

	var download_button: Button = Button.new()
	download_button.text = "Download"
	download_button.pressed.connect(_on_row_download_pressed.bind(model_id))
	top.add_child(download_button)

	var installed_label: Label = Label.new()
	installed_label.text = "✓ Installed"
	installed_label.visible = false
	top.add_child(installed_label)

	var cancel_button: Button = Button.new()
	cancel_button.text = "Cancel"
	cancel_button.visible = false
	cancel_button.pressed.connect(_on_row_cancel_pressed)
	top.add_child(cancel_button)

	# Bottom line: progress bar + byte/ETA readout (hidden until a download runs).
	var progress_row: HBoxContainer = HBoxContainer.new()
	progress_row.add_theme_constant_override("separation", 8)
	progress_row.visible = false
	vbox.add_child(progress_row)

	var progress_bar: ProgressBar = ProgressBar.new()
	progress_bar.min_value = 0.0
	progress_bar.max_value = 100.0
	progress_bar.value = 0.0
	progress_bar.custom_minimum_size = Vector2(220, 0)
	progress_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	progress_row.add_child(progress_bar)

	var progress_label: Label = Label.new()
	progress_label.text = ""
	progress_row.add_child(progress_label)

	var row: Dictionary = {
		"model": model,
		"name_label": name_label,
		"download_button": download_button,
		"installed_label": installed_label,
		"cancel_button": cancel_button,
		"progress_row": progress_row,
		"progress_bar": progress_bar,
		"progress_label": progress_label,
	}
	_rows[model_id] = row
	return panel

# -- Row state ----------------------------------------------------------------

func _refresh_all_rows() -> void:
	for model_id: String in _rows.keys():
		if String(model_id) == _demo_installed_id:
			_set_row_installed(String(model_id))
		elif _manager.is_model_installed(String(model_id)):
			_set_row_installed(String(model_id))
		else:
			_set_row_available(String(model_id))
	_set_status("Choose a model to download. Files are saved under user://local_agents/models.")

func _set_row_available(model_id: String) -> void:
	var row: Dictionary = _rows.get(model_id, {})
	if row.is_empty():
		return
	(row["download_button"] as Button).visible = true
	(row["download_button"] as Button).disabled = false
	(row["installed_label"] as Label).visible = false
	(row["cancel_button"] as Button).visible = false
	(row["progress_row"] as HBoxContainer).visible = false

func _set_row_installed(model_id: String) -> void:
	var row: Dictionary = _rows.get(model_id, {})
	if row.is_empty():
		return
	(row["download_button"] as Button).visible = false
	(row["installed_label"] as Label).visible = true
	(row["cancel_button"] as Button).visible = false
	(row["progress_row"] as HBoxContainer).visible = false

func _set_row_downloading(model_id: String) -> void:
	var row: Dictionary = _rows.get(model_id, {})
	if row.is_empty():
		return
	(row["download_button"] as Button).visible = false
	(row["installed_label"] as Label).visible = false
	(row["cancel_button"] as Button).visible = true
	(row["progress_row"] as HBoxContainer).visible = true
	(row["progress_bar"] as ProgressBar).value = 0.0
	(row["progress_label"] as Label).text = "Starting…"

func _set_status(text: String) -> void:
	if _status_label != null:
		_status_label.text = text

# -- Button handlers ----------------------------------------------------------

func _on_row_download_pressed(model_id: String) -> void:
	if _manager.is_downloading():
		_set_status("A download is already in progress.")
		return
	_set_row_downloading(model_id)
	# Disable every other row's Download button while one transfer runs.
	for other_id: String in _rows.keys():
		if String(other_id) != model_id:
			var other: Dictionary = _rows[other_id]
			(other["download_button"] as Button).disabled = true
	if not _manager.start_download(model_id):
		_set_status("Could not start download (offline or unavailable).")
		_refresh_all_rows()

func _on_row_cancel_pressed() -> void:
	if _manager.is_downloading():
		_manager.cancel()

# -- Manager signal handlers --------------------------------------------------

func _on_download_started(model_id: String, total_bytes: int) -> void:
	var name: String = _model_name(model_id)
	_set_status("Downloading %s (%s)…" % [name, ModelDownloadManager.format_bytes(total_bytes)])

func _on_download_progress(model_id: String, received_bytes: int, total_bytes: int, speed_bytes_per_sec: float, eta_seconds: float) -> void:
	var row: Dictionary = _rows.get(model_id, {})
	if row.is_empty():
		return
	var bar: ProgressBar = row["progress_bar"] as ProgressBar
	var label: Label = row["progress_label"] as Label
	if total_bytes > 0:
		bar.value = clamp(float(received_bytes) / float(total_bytes) * 100.0, 0.0, 100.0)
	var received_text: String = ModelDownloadManager.format_bytes(received_bytes)
	var total_text: String = ModelDownloadManager.format_bytes(total_bytes) if total_bytes > 0 else "?"
	var speed_text: String = ModelDownloadManager.format_speed(speed_bytes_per_sec)
	var eta_text: String = ModelDownloadManager.format_eta(eta_seconds)
	label.text = "%s / %s   ·   %s   ·   %s" % [received_text, total_text, speed_text, eta_text]

func _on_download_finished(model_id: String, ok: bool, path: String, error: String) -> void:
	# Re-enable all Download buttons.
	for other_id: String in _rows.keys():
		var other: Dictionary = _rows[other_id]
		(other["download_button"] as Button).disabled = false
	var name: String = _model_name(model_id)
	if ok:
		_set_row_installed(model_id)
		_set_status("%s installed." % name)
	else:
		_set_row_available(model_id)
		if error == "cancelled":
			_set_status("%s download cancelled." % name)
		else:
			_set_status("%s download failed (%s)." % [name, error])

func _on_model_installed(model_id: String, path: String) -> void:
	model_installed.emit(model_id, path)

func _model_name(model_id: String) -> String:
	var row: Dictionary = _rows.get(model_id, {})
	if row.is_empty():
		return model_id
	var model: Dictionary = row.get("model", {})
	return String(model.get("label", model_id))
