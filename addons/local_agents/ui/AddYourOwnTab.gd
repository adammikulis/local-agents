extends VBoxContainer
class_name LocalAgentsAddYourOwnTab

# "Add your own" tab of the model manager.
#
# Three ways for a player to bring a model the catalog does not ship:
#   1. Browse to a local .gguf and register it as a selectable model (persisted).
#   2. Pull an arbitrary GGUF by Hugging Face repo id + filename (routed through the download manager).
#   3. Point detection at extra folders / a custom HF cache location (persisted, feeds every scan).

const ModelDownloadManager: GDScript = preload("res://addons/local_agents/ui/ModelDownloadManager.gd")

signal active_model_changed(path: String)
signal registry_changed()

var _store: LocalAgentsModelSettingsStore = null
var _download_manager: LocalAgentsModelDownloadManager = null

var _browse_dialog: FileDialog = null
var _folder_dialog: FileDialog = null
var _repo_edit: LineEdit = null
var _file_edit: LineEdit = null
var _download_button: Button = null
var _download_status: Label = null
var _registered_box: VBoxContainer = null
var _folders_box: VBoxContainer = null
var _hf_edit: LineEdit = null

func setup(store: LocalAgentsModelSettingsStore) -> void:
	_store = store
	_download_manager = ModelDownloadManager.new()
	_download_manager.name = "CustomDownloadManager"
	add_child(_download_manager)
	_download_manager.download_progress.connect(_on_download_progress)
	_download_manager.download_finished.connect(_on_download_finished)
	_download_manager.model_installed.connect(_on_model_installed)
	_build()

func _build() -> void:
	add_theme_constant_override("separation", 12)

	# -- 1. Browse to a local .gguf --
	_add_heading("Use a model file you already have")
	var browse_row: HBoxContainer = HBoxContainer.new()
	browse_row.add_theme_constant_override("separation", 8)
	add_child(browse_row)
	var browse_button: Button = Button.new()
	browse_button.text = "Browse for .gguf…"
	browse_button.pressed.connect(_on_browse_pressed)
	browse_row.add_child(browse_button)
	var browse_hint: Label = Label.new()
	browse_hint.text = "Registers a local GGUF as a selectable model."
	browse_hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	browse_row.add_child(browse_hint)

	_browse_dialog = FileDialog.new()
	_browse_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_browse_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_browse_dialog.filters = PackedStringArray(["*.gguf ; GGUF models"])
	_browse_dialog.use_native_dialog = false
	_browse_dialog.file_selected.connect(_on_gguf_selected)
	add_child(_browse_dialog)

	# -- 2. Pull by HF repo id --
	_add_heading("Download by Hugging Face repo")
	var repo_row: HBoxContainer = HBoxContainer.new()
	repo_row.add_theme_constant_override("separation", 8)
	add_child(repo_row)
	_repo_edit = LineEdit.new()
	_repo_edit.placeholder_text = "org/repo (e.g. unsloth/Qwen3-4B-Instruct-2507-GGUF)"
	_repo_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	repo_row.add_child(_repo_edit)
	_file_edit = LineEdit.new()
	_file_edit.placeholder_text = "filename.gguf"
	_file_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	repo_row.add_child(_file_edit)
	_download_button = Button.new()
	_download_button.text = "Download"
	_download_button.pressed.connect(_on_repo_download_pressed)
	repo_row.add_child(_download_button)
	_download_status = Label.new()
	_download_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_download_status)

	# -- 3. Registered custom models --
	_add_heading("Your registered models")
	_registered_box = VBoxContainer.new()
	_registered_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_registered_box.add_theme_constant_override("separation", 6)
	add_child(_registered_box)

	# -- 4. Extra detection locations --
	_add_heading("Where to look for models")
	var hf_row: HBoxContainer = HBoxContainer.new()
	hf_row.add_theme_constant_override("separation", 8)
	add_child(hf_row)
	var hf_label: Label = Label.new()
	hf_label.text = "HF cache:"
	hf_row.add_child(hf_label)
	_hf_edit = LineEdit.new()
	_hf_edit.placeholder_text = "auto (HF_HUB_CACHE / HF_HOME / ~/.cache/huggingface/hub)"
	_hf_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_hf_edit.text_submitted.connect(_on_hf_submitted)
	hf_row.add_child(_hf_edit)
	var hf_save: Button = Button.new()
	hf_save.text = "Save"
	hf_save.pressed.connect(func() -> void: _on_hf_submitted(_hf_edit.text))
	hf_row.add_child(hf_save)

	var folder_row: HBoxContainer = HBoxContainer.new()
	folder_row.add_theme_constant_override("separation", 8)
	add_child(folder_row)
	var add_folder_button: Button = Button.new()
	add_folder_button.text = "Add models folder…"
	add_folder_button.pressed.connect(_on_add_folder_pressed)
	folder_row.add_child(add_folder_button)
	var folder_hint: Label = Label.new()
	folder_hint.text = "Extra folders are scanned on the Installed / detected tab."
	folder_hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	folder_row.add_child(folder_hint)

	_folder_dialog = FileDialog.new()
	_folder_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	_folder_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_folder_dialog.use_native_dialog = false
	_folder_dialog.dir_selected.connect(_on_folder_selected)
	add_child(_folder_dialog)

	_folders_box = VBoxContainer.new()
	_folders_box.add_theme_constant_override("separation", 4)
	add_child(_folders_box)

func refresh() -> void:
	if _store != null and _hf_edit != null:
		_hf_edit.text = _store.hf_cache_override
	_rebuild_registered()
	_rebuild_folders()

func _add_heading(text: String) -> void:
	var label: Label = Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 16)
	add_child(label)

# -- Registered-model list ----------------------------------------------------

func _rebuild_registered() -> void:
	if _registered_box == null:
		return
	for child: Node in _registered_box.get_children():
		child.queue_free()
	if _store == null or _store.registered_models.is_empty():
		var empty: Label = Label.new()
		empty.text = "No custom models yet."
		empty.modulate = Color(0.7, 0.7, 0.7)
		_registered_box.add_child(empty)
		return
	for entry: Dictionary in _store.registered_models:
		_registered_box.add_child(_make_registered_row(entry))

func _make_registered_row(entry: Dictionary) -> Control:
	var path: String = String(entry.get("path", ""))
	var label: String = String(entry.get("label", path.get_file()))
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)

	var name_label: Label = Label.new()
	name_label.text = label
	name_label.tooltip_text = path
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	row.add_child(name_label)

	var is_active: bool = _store != null and _store.active_model_path == path
	var use_button: Button = Button.new()
	use_button.text = "Active" if is_active else "Use"
	use_button.disabled = is_active
	use_button.pressed.connect(_on_use_pressed.bind(path))
	row.add_child(use_button)

	var remove_button: Button = Button.new()
	remove_button.text = "Remove"
	remove_button.pressed.connect(_on_remove_pressed.bind(path))
	row.add_child(remove_button)
	return row

func _rebuild_folders() -> void:
	if _folders_box == null:
		return
	for child: Node in _folders_box.get_children():
		child.queue_free()
	if _store == null:
		return
	for folder: String in _store.custom_folders:
		var row: HBoxContainer = HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		var label: Label = Label.new()
		label.text = folder
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(label)
		var remove_button: Button = Button.new()
		remove_button.text = "Remove"
		remove_button.pressed.connect(_on_remove_folder_pressed.bind(folder))
		row.add_child(remove_button)
		_folders_box.add_child(row)

# -- Handlers -----------------------------------------------------------------

func _on_browse_pressed() -> void:
	_browse_dialog.popup_centered_ratio(0.7)

func _on_gguf_selected(path: String) -> void:
	if _store == null:
		return
	if _store.register_model(path):
		_store.save()
		_rebuild_registered()
		registry_changed.emit()
		_download_status.text = "Registered %s." % path.get_file()
	else:
		_download_status.text = "%s is already registered." % path.get_file()

func _on_add_folder_pressed() -> void:
	_folder_dialog.popup_centered_ratio(0.7)

func _on_folder_selected(path: String) -> void:
	if _store == null:
		return
	if not _store.custom_folders.has(path):
		_store.custom_folders.append(path)
		_store.save()
		_rebuild_folders()
		registry_changed.emit()

func _on_remove_folder_pressed(path: String) -> void:
	if _store == null:
		return
	var kept: PackedStringArray = PackedStringArray()
	for folder: String in _store.custom_folders:
		if folder != path:
			kept.append(folder)
	_store.custom_folders = kept
	_store.save()
	_rebuild_folders()
	registry_changed.emit()

func _on_hf_submitted(text: String) -> void:
	if _store == null:
		return
	_store.hf_cache_override = text.strip_edges()
	_store.save()
	registry_changed.emit()
	_download_status.text = "Saved HF cache location."

func _on_repo_download_pressed() -> void:
	if _download_manager.is_downloading():
		_download_status.text = "A download is already in progress."
		return
	var repo: String = _repo_edit.text.strip_edges()
	var file: String = _file_edit.text.strip_edges()
	if repo == "" or file == "":
		_download_status.text = "Enter both a repo id and a filename."
		return
	_download_button.disabled = true
	if not _download_manager.start_download_custom(repo, file):
		_download_button.disabled = false
		_download_status.text = "Could not start download (offline or invalid input)."

func _on_download_progress(_model_id: String, received: int, total: int, speed: float, eta: float) -> void:
	var received_text: String = LocalAgentsModelDownloadManager.format_bytes(received)
	var total_text: String = LocalAgentsModelDownloadManager.format_bytes(total) if total > 0 else "?"
	_download_status.text = "%s / %s · %s · %s" % [received_text, total_text, LocalAgentsModelDownloadManager.format_speed(speed), LocalAgentsModelDownloadManager.format_eta(eta)]

func _on_download_finished(_model_id: String, ok: bool, path: String, error: String) -> void:
	_download_button.disabled = false
	if ok:
		_download_status.text = "Downloaded %s." % path.get_file()
	else:
		_download_status.text = "Download failed (%s)." % error

func _on_model_installed(_model_id: String, path: String) -> void:
	if _store == null:
		return
	if _store.register_model(path):
		_store.save()
		_rebuild_registered()
		registry_changed.emit()

func _on_use_pressed(path: String) -> void:
	if _store == null:
		return
	_store.active_model_path = path
	_store.save()
	active_model_changed.emit(path)
	_rebuild_registered()

func _on_remove_pressed(path: String) -> void:
	if _store == null:
		return
	_store.unregister_model(path)
	_store.save()
	_rebuild_registered()
	registry_changed.emit()
