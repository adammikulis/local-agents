extends Control
class_name LAModelManagerPanel


signal active_model_changed(path: String)

var _store: LocalAgentModelSettingsStore = null
var _inventory: LocalAgentModelInventory = null

@onready var _tabs: TabContainer = %Tabs
@onready var _active_label: Label = %ActiveLabel
# Quoted paths: the tab titles are the node names, and they contain spaces.
@onready var _detected_tab: LADetectedModelsTab = $"Background/Margin/Body/Tabs/Installed _ detected"
@onready var _add_tab: LAAddYourOwnTab = $"Background/Margin/Body/Tabs/Add your own"
@onready var _inference_tab: LAInferenceSettingsTab = $"Background/Margin/Body/Tabs/Inference settings"

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

	# A TabContainer titles each tab with its node NAME, and Node.set_name strips "/", so the second tab has
	# always read "Installed _ detected". Titles are set here because they are not node names.
	var tabs: TabContainer = $Background/Margin/Body/Tabs
	tabs.set_tab_title(tabs.get_tab_idx_from_control(_detected_tab), "Installed / detected")

	_store = LocalAgentModelSettingsStore.new()
	_store.load()
	_inventory = LocalAgentModelInventory.new()

	if is_scene_root and _fake_hf_cache != "":
		_store.hf_cache_override = _fake_hf_cache
	if is_scene_root and _demo_register != "":
		_store.register_model(_demo_register, "My local model")

	_wire()
	refresh()

	if is_scene_root and (_shoot_path != "" or OS.has_environment("LA_OFFSCREEN")):
		LAQuietWindow.apply()
	if is_scene_root and _shoot_path != "":
		if _tabs != null and _shoot_tab >= 0 and _shoot_tab < _tabs.get_tab_count():
			_tabs.current_tab = _shoot_tab
		set_process(true)

func _wire() -> void:
	_detected_tab.setup(_inventory, _store)
	_detected_tab.active_model_changed.connect(_on_active_model_changed)
	_add_tab.setup(_store)
	_add_tab.active_model_changed.connect(_on_active_model_changed)
	_add_tab.registry_changed.connect(_on_registry_changed)
	_inference_tab.setup(_store, _inventory)


func open() -> void:
	visible = true
	refresh()

func close() -> void:
	visible = false

func settings_store() -> LocalAgentModelSettingsStore:
	return _store

func inventory() -> LocalAgentModelInventory:
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


var _fake_hf_cache: String = ""
var _demo_register: String = ""

func _run_selftest_if_requested() -> bool:
	for arg: String in OS.get_cmdline_user_args():
		if arg == "--model-manager-selftest":
			var store_report: Dictionary = LocalAgentModelSettingsStore.run_selftest()
			var inv_report: Dictionary = LocalAgentModelInventory.run_selftest()
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
