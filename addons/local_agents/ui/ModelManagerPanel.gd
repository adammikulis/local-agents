extends Control
class_name LocalAgentsModelManagerPanel

# In-game model manager: one panel, four tabs.
#
#   Download            - the existing curated downloader (ModelDownloadPanel), embedded as-is.
#   Installed / detected - models already on disk (local folder + HF cache + custom folders).
#   Add your own        - browse to a .gguf, pull by HF repo id, or add scan locations.
#   Inference settings  - context length / sampling / GPU layers / system prompt / per-role models.
#
# Everything reuses existing pieces: LocalAgentsModelDownloadManager + catalog for downloads,
# LocalAgentsModelInventory for detection, LocalAgentsModelSettingsStore (backed by
# LocalAgentsInferenceParams) for persisted config. No sim/field files are touched.
#
# Public API:
#   open()                  -> show + refresh every tab
#   close()                 -> hide
#   settings_store()        -> LocalAgentsModelSettingsStore (live)
#   inventory()             -> LocalAgentsModelInventory
#   active_model_path()     -> String  (the player's chosen model, or "")
#   inference_options()     -> Dictionary  (ready for LlamaServerManager.ensure_running)
#   model_for_role(role)    -> String
#
# Self-harness (standalone scene only):
#   --model-manager-selftest        run store + inventory round-trip, print MODEL_MANAGER_SELFTEST, quit
#   --shoot=<png> [--shoot-frames=N] [--shoot-tab=I]   off-screen screenshot of tab I
#   --fake-hf-cache=<dir>           point detection at a fake HF cache (detection proof)
#   --demo-register=<path.gguf>     register a custom model before the shot (BYO proof)

const ModelDownloadPanelScene: PackedScene = preload("res://addons/local_agents/ui/ModelDownloadPanel.tscn")
const DetectedTab: GDScript = preload("res://addons/local_agents/ui/DetectedModelsTab.gd")
const AddYourOwnTab: GDScript = preload("res://addons/local_agents/ui/AddYourOwnTab.gd")
const InferenceTab: GDScript = preload("res://addons/local_agents/ui/InferenceSettingsTab.gd")

signal active_model_changed(path: String)

var _store: LocalAgentsModelSettingsStore = null
var _inventory: LocalAgentsModelInventory = null

var _tabs: TabContainer = null
var _active_label: Label = null
var _detected_tab: LocalAgentsDetectedModelsTab = null
var _add_tab: LocalAgentsAddYourOwnTab = null
var _inference_tab: LocalAgentsInferenceSettingsTab = null

# Self-harness state.
var _shoot_path: String = ""
var _shoot_frames: int = 14
var _shoot_tab: int = 1
var _shoot_counter: int = 0

func _ready() -> void:
	var is_scene_root: bool = get_tree() != null and get_tree().current_scene == self
	if is_scene_root and _run_selftest_if_requested():
		return
	if is_scene_root:
		_parse_cmdline()

	_store = LocalAgentsModelSettingsStore.new()
	_store.load()
	_inventory = LocalAgentsModelInventory.new()

	if is_scene_root and _fake_hf_cache != "":
		_store.hf_cache_override = _fake_hf_cache
	if is_scene_root and _demo_register != "":
		_store.register_model(_demo_register, "My local model")

	_build()
	refresh()

	if is_scene_root and (_shoot_path != "" or OS.has_environment("LA_OFFSCREEN")):
		DisplayServer.window_set_position(Vector2i(-8000, -8000))
	if is_scene_root and _shoot_path != "":
		if _tabs != null and _shoot_tab >= 0 and _shoot_tab < _tabs.get_tab_count():
			_tabs.current_tab = _shoot_tab
		set_process(true)

func _build() -> void:
	var bg: PanelContainer = PanelContainer.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var margin: MarginContainer = MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 20)
	margin.add_theme_constant_override("margin_right", 20)
	margin.add_theme_constant_override("margin_top", 16)
	margin.add_theme_constant_override("margin_bottom", 16)
	bg.add_child(margin)

	var body: VBoxContainer = VBoxContainer.new()
	body.add_theme_constant_override("separation", 10)
	margin.add_child(body)

	var header: HBoxContainer = HBoxContainer.new()
	header.add_theme_constant_override("separation", 12)
	body.add_child(header)
	var title: Label = Label.new()
	title.text = "Models"
	title.add_theme_font_size_override("font_size", 22)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	_active_label = Label.new()
	header.add_child(_active_label)

	_tabs = TabContainer.new()
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tabs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_child(_tabs)

	# 1. Download (existing panel embedded).
	var download_panel: Control = ModelDownloadPanelScene.instantiate()
	download_panel.name = "Download"
	_tabs.add_child(download_panel)

	# 2. Installed / detected.
	_detected_tab = DetectedTab.new()
	_detected_tab.name = "Installed / detected"
	_tabs.add_child(_detected_tab)
	_detected_tab.setup(_inventory, _store)
	_detected_tab.active_model_changed.connect(_on_active_model_changed)

	# 3. Add your own.
	_add_tab = AddYourOwnTab.new()
	_add_tab.name = "Add your own"
	_tabs.add_child(_add_tab)
	_add_tab.setup(_store)
	_add_tab.active_model_changed.connect(_on_active_model_changed)
	_add_tab.registry_changed.connect(_on_registry_changed)

	# 4. Inference settings.
	_inference_tab = InferenceTab.new()
	_inference_tab.name = "Inference settings"
	_tabs.add_child(_inference_tab)
	_inference_tab.setup(_store, _inventory)

# -- Public API ---------------------------------------------------------------

func open() -> void:
	visible = true
	refresh()

func close() -> void:
	visible = false

func settings_store() -> LocalAgentsModelSettingsStore:
	return _store

func inventory() -> LocalAgentsModelInventory:
	return _inventory

func active_model_path() -> String:
	return _store.active_model_path if _store != null else ""

func inference_options() -> Dictionary:
	return _store.to_llama_options() if _store != null else {}

func model_for_role(role: String) -> String:
	return _store.model_for_role(role) if _store != null else ""

func refresh() -> void:
	if _detected_tab != null:
		_detected_tab.refresh()
	if _add_tab != null:
		_add_tab.refresh()
	if _inference_tab != null:
		_inference_tab.refresh()
	_update_active_label()

func _update_active_label() -> void:
	if _active_label == null:
		return
	var path: String = active_model_path()
	_active_label.text = "Active: %s" % (path.get_file() if path != "" else "none")

func _on_active_model_changed(path: String) -> void:
	_update_active_label()
	if _inference_tab != null:
		_inference_tab.refresh()
	active_model_changed.emit(path)

func _on_registry_changed() -> void:
	if _detected_tab != null:
		_detected_tab.refresh()
	if _inference_tab != null:
		_inference_tab.refresh()

# -- Self-harness -------------------------------------------------------------

var _fake_hf_cache: String = ""
var _demo_register: String = ""

func _run_selftest_if_requested() -> bool:
	for arg: String in OS.get_cmdline_user_args():
		if arg == "--model-manager-selftest":
			var store_report: Dictionary = LocalAgentsModelSettingsStore.run_selftest()
			var inv_report: Dictionary = LocalAgentsModelInventory.run_selftest()
			var report: Dictionary = {
				"ok": bool(store_report.get("ok", false)) and bool(inv_report.get("ok", false)),
				"settings": store_report,
				"inventory": inv_report,
			}
			print("MODEL_MANAGER_SELFTEST=%s" % JSON.stringify(report))
			get_tree().quit(0 if bool(report.get("ok", false)) else 1)
			return true
	return false

func _parse_cmdline() -> void:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--shoot="):
			_shoot_path = arg.substr("--shoot=".length())
		elif arg.begins_with("--shoot-frames="):
			_shoot_frames = int(arg.substr("--shoot-frames=".length()))
		elif arg.begins_with("--shoot-tab="):
			_shoot_tab = int(arg.substr("--shoot-tab=".length()))
		elif arg.begins_with("--fake-hf-cache="):
			_fake_hf_cache = arg.substr("--fake-hf-cache=".length())
		elif arg.begins_with("--demo-register="):
			_demo_register = arg.substr("--demo-register=".length())

func _process(_delta: float) -> void:
	if _shoot_path == "":
		return
	_shoot_counter += 1
	if _shoot_counter == _shoot_frames:
		var img: Image = get_viewport().get_texture().get_image()
		img.save_png(_shoot_path)
		print("SHOT_SAVED=%s size=%dx%d" % [_shoot_path, img.get_width(), img.get_height()])
		get_tree().quit(0)
