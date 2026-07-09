extends VBoxContainer
class_name LocalAgentsDetectedModelsTab

# "Installed / detected" tab of the model manager.
#
# Shows the shipped-catalog models with a live on-disk status (already usable in the local folder or
# found in the HF cache, versus not downloaded), plus any loose GGUFs discovered elsewhere on disk.
# Each already-present model gets a "Use this model" button that sets it as the active model — so the
# player reuses what they already have instead of re-downloading.

const ModelDownloadService: GDScript = preload("res://addons/local_agents/controllers/ModelDownloadService.gd")

signal active_model_changed(path: String)

var _inventory: LocalAgentsModelInventory = null
var _store: LocalAgentsModelSettingsStore = null
var _service: LocalAgentsModelDownloadService = null

var _list_box: VBoxContainer = null
var _status: Label = null

func setup(inventory: LocalAgentsModelInventory, store: LocalAgentsModelSettingsStore) -> void:
	_inventory = inventory
	_store = store
	_service = ModelDownloadService.new()
	_build()

func _build() -> void:
	add_theme_constant_override("separation", 10)

	var intro: Label = Label.new()
	intro.text = "Models already on this machine. Anything found here can be used in place — no re-download needed."
	intro.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(intro)

	var scroll: ScrollContainer = ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(scroll)

	_list_box = VBoxContainer.new()
	_list_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list_box.add_theme_constant_override("separation", 8)
	scroll.add_child(_list_box)

	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_status)

func refresh() -> void:
	if _list_box == null:
		return
	for child: Node in _list_box.get_children():
		child.queue_free()

	var extra: PackedStringArray = _store.custom_folders if _store != null else PackedStringArray()
	var hf_override: String = _store.hf_cache_override if _store != null else ""
	var detected: Array = _inventory.scan(extra, hf_override)

	# Index detected files by lower-case filename so catalog rows can find their on-disk match.
	var by_filename: Dictionary = {}
	for row: Dictionary in detected:
		by_filename[String(row.get("filename", "")).to_lower()] = row

	var catalog_filenames: Dictionary = {}
	var catalog_rows: int = 0
	for family: Dictionary in _service.list_families():
		for model: Dictionary in family.get("models", []):
			var filename: String = String(model.get("filename", ""))
			catalog_filenames[filename.to_lower()] = true
			var hit: Dictionary = by_filename.get(filename.to_lower(), {})
			_list_box.add_child(_make_catalog_row(model, hit))
			catalog_rows += 1

	# Loose GGUFs that are not part of the shipped catalog (the player's own downloads).
	var loose: int = 0
	for row: Dictionary in detected:
		if catalog_filenames.has(String(row.get("filename", "")).to_lower()):
			continue
		_list_box.add_child(_make_loose_row(row))
		loose += 1

	var active: String = _store.active_model_path if _store != null else ""
	if active != "":
		_status.text = "Active model: %s" % active.get_file()
	else:
		_status.text = "Scanned %d catalog models and found %d other GGUF file(s) on disk." % [catalog_rows, loose]

func _make_catalog_row(model: Dictionary, hit: Dictionary) -> Control:
	var label: String = String(model.get("label", model.get("id", "model")))
	var found: bool = not hit.is_empty()
	var status_text: String = ""
	if found:
		var source: String = String(hit.get("source", ""))
		if source == LocalAgentsModelInventory.SOURCE_HF:
			status_text = "Installed (found in HF cache)"
		elif source == LocalAgentsModelInventory.SOURCE_FOLDER:
			status_text = "Installed (custom folder)"
		else:
			status_text = "Installed (local folder)"
	else:
		status_text = "Not downloaded"
	return _make_row(label, status_text, found, String(hit.get("path", "")))

func _make_loose_row(row: Dictionary) -> Control:
	var filename: String = String(row.get("filename", ""))
	var size_pretty: String = LocalAgentsModelDownloadManager.format_bytes(int(row.get("size_bytes", 0)))
	var status_text: String = "%s · %s" % [String(row.get("source_label", "")), size_pretty]
	return _make_row(filename, status_text, true, String(row.get("path", "")))

func _make_row(title: String, status_text: String, usable: bool, path: String) -> Control:
	var panel: PanelContainer = PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var margin: MarginContainer = MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 10)
	margin.add_theme_constant_override("margin_right", 10)
	margin.add_theme_constant_override("margin_top", 6)
	margin.add_theme_constant_override("margin_bottom", 6)
	panel.add_child(margin)

	var hbox: HBoxContainer = HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 12)
	margin.add_child(hbox)

	var text_box: VBoxContainer = VBoxContainer.new()
	text_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(text_box)

	var name_label: Label = Label.new()
	name_label.text = title
	name_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	text_box.add_child(name_label)

	var status_label: Label = Label.new()
	status_label.text = status_text
	status_label.add_theme_font_size_override("font_size", 12)
	status_label.modulate = Color(0.6, 0.85, 0.6) if usable else Color(0.7, 0.7, 0.7)
	text_box.add_child(status_label)

	if usable and path != "":
		var is_active: bool = _store != null and _store.active_model_path == path
		var use_button: Button = Button.new()
		use_button.text = "Active" if is_active else "Use this model"
		use_button.disabled = is_active
		use_button.pressed.connect(_on_use_pressed.bind(path))
		hbox.add_child(use_button)

	return panel

func _on_use_pressed(path: String) -> void:
	if _store == null:
		return
	_store.active_model_path = path
	_store.save()
	active_model_changed.emit(path)
	refresh()
