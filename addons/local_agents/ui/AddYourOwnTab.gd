extends VBoxContainer
class_name LAAddYourOwnTab


signal active_model_changed(path: String)
signal registry_changed()

var _store: LocalAgentModelSettingsStore = null

@onready var _download_manager: LAModelDownloadManager = %CustomDownloadManager
@onready var _browse_button: Button = %BrowseButton
@onready var _browse_dialog: FileDialog = %BrowseDialog
@onready var _folder_dialog: FileDialog = %FolderDialog
@onready var _repo_edit: LineEdit = %RepoEdit
@onready var _file_edit: LineEdit = %FileEdit
@onready var _download_button: Button = %DownloadButton
@onready var _download_status: Label = %DownloadStatus
@onready var _registered_box: VBoxContainer = %RegisteredBox
@onready var _folders_box: VBoxContainer = %FoldersBox
@onready var _hf_edit: LineEdit = %HfEdit
@onready var _hf_save_button: Button = %HfSaveButton
@onready var _add_folder_button: Button = %AddFolderButton

func _ready() -> void:
	_download_manager.download_progress.connect(_on_download_progress)
	_download_manager.download_finished.connect(_on_download_finished)
	_download_manager.model_installed.connect(_on_model_installed)
	_browse_button.pressed.connect(_on_browse_pressed)
	_browse_dialog.file_selected.connect(_on_gguf_selected)
	_download_button.pressed.connect(_on_repo_download_pressed)
	_hf_edit.text_submitted.connect(_on_hf_submitted)
	_hf_save_button.pressed.connect(_on_hf_save_pressed)
	_add_folder_button.pressed.connect(_on_add_folder_pressed)
	_folder_dialog.dir_selected.connect(_on_folder_selected)

func setup(store: LocalAgentModelSettingsStore) -> void:
	_store = store

func refresh() -> void:
	if _store != null:
		_hf_edit.text = _store.hf_cache_override
	_rebuild_registered()
	_rebuild_folders()


func _rebuild_registered() -> void:
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

func _on_hf_save_pressed() -> void:
	_on_hf_submitted(_hf_edit.text)

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
	var received_text: String = LAModelDownloadManager.format_bytes(received)
	var total_text: String = LAModelDownloadManager.format_bytes(total) if total > 0 else "?"
	_download_status.text = "%s / %s · %s · %s" % [received_text, total_text, LAModelDownloadManager.format_speed(speed), LAModelDownloadManager.format_eta(eta)]

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
