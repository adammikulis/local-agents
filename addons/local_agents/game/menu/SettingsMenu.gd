class_name LASettingsMenu
extends Control

## The settings screen. It edits the live LAGameSettings held on the GameMode autoload. The panel shell,
## the action bar and the status line live in SettingsMenu.tscn; the four setting groups (difficulty,
## graphics, simulation/AI, audio, controls) are generated into the Sections column from the settings
## resource by LASettingsWidgets and the two section objects. "Save" persists to user:// and calls
## GameMode.apply(); "Back" returns to the main menu.

const MAIN_MENU_SCENE: String = "res://addons/local_agents/game/menu/MainMenu.tscn"
const ModelManagerPanelScene: PackedScene = preload("res://addons/local_agents/ui/ModelManagerPanel.tscn")

var _settings: LAGameSettings = null

var _difficulty_group: ButtonGroup = null
var _difficulty_buttons: Dictionary = {}   # Difficulty enum -> Button

var _disaster_slider: HSlider = null
var _disaster_value: Label = null
var _climate_slider: HSlider = null
var _climate_value: Label = null
var _master_value: Label = null
var _music_value: Label = null
var _sfx_value: Label = null
var _invert_x_option: OptionButton = null
var _invert_y_option: OptionButton = null

var _graphics: LAGraphicsSettingsSection = null
var _sim: LASimSettingsSection = null

var _suppress: bool = false

@onready var _scroll: ScrollContainer = $Center/Panel/Scroll
@onready var _sections: VBoxContainer = $Center/Panel/Scroll/Column/Sections
@onready var _save_button: Button = $Center/Panel/Scroll/Column/Actions/Save
@onready var _models_button: Button = $Center/Panel/Scroll/Column/Actions/Models
@onready var _back_button: Button = $Center/Panel/Scroll/Column/Actions/Back
@onready var _status_label: Label = $Center/Panel/Scroll/Column/Status


func _ready() -> void:
	_settings = GameMode.settings
	if _settings == null:
		_settings = LAGameSettings.load_or_default()
		GameMode.settings = _settings
	_build_sections()
	_save_button.pressed.connect(_on_save)
	_models_button.pressed.connect(_on_models)
	_back_button.pressed.connect(_on_back)
	_refresh_difficulty()
	_save_button.grab_focus()

	# Screenshot verification: grow the scroll viewport so the whole settings list renders into one tall
	# frame for --shoot. Inert in normal play.
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if args.has("--shoot") or _has_prefix(args, "--shoot="):
		_scroll.custom_minimum_size = Vector2(500.0, 1520.0)
	if args.has("--dump-tooltips"):
		call_deferred("_dump_tooltips")
	if args.has("--demo-custom"):
		# Drive the real value_changed handler in each performance category, exactly as a player drag would.
		if _graphics != null:
			_graphics.demo_nudge()
		if _sim != null:
			_sim.demo_nudge()
	add_child(LAMenuShooter.new())


func _build_sections() -> void:
	# --- Difficulty ---
	LASettingsWidgets.add_header(_sections, "Difficulty")
	_difficulty_group = ButtonGroup.new()
	var diff_row: HBoxContainer = LASettingsWidgets.add_row(_sections)
	_add_difficulty(diff_row, LAGameSettings.Difficulty.PEACEFUL, "Peaceful", "Rare, mild disasters and a gentle climate. Gameplay difficulty.")
	_add_difficulty(diff_row, LAGameSettings.Difficulty.NORMAL, "Normal", "A balanced cadence of disasters and climate swings. Gameplay difficulty.")
	_add_difficulty(diff_row, LAGameSettings.Difficulty.HARSH, "Harsh", "Frequent, severe disasters and an extreme climate. Gameplay difficulty.")

	var dis: Dictionary = LASettingsWidgets.add_slider(_sections, "Disaster frequency",
		"How often ambient natural disasters are seeded into the world. Gameplay, not performance.",
		0.0, 1.0, 0.01, _settings.disaster_frequency, Callable(self, "_fmt_percent"), Callable(self, "_on_disaster_changed"))
	_disaster_slider = dis["slider"]
	_disaster_value = dis["value"]
	var cli: Dictionary = LASettingsWidgets.add_slider(_sections, "Climate harshness",
		"How extreme the climate swings and which disasters lean in. Gameplay, not performance.",
		0.0, 1.0, 0.01, _settings.climate_harshness, Callable(self, "_fmt_percent"), Callable(self, "_on_climate_changed"))
	_climate_slider = cli["slider"]
	_climate_value = cli["value"]

	# --- Graphics (GPU) ---
	_graphics = LAGraphicsSettingsSection.new()
	_graphics.setup(_settings, Callable(self, "_on_section_changed"))
	_graphics.build(_sections)

	# --- Simulation / AI (CPU) ---
	_sim = LASimSettingsSection.new()
	_sim.setup(_settings, Callable(self, "_on_section_changed"))
	_sim.build(_sections)

	# --- Audio ---
	LASettingsWidgets.add_header(_sections, "Audio")
	var mv: Dictionary = LASettingsWidgets.add_slider(_sections, "Master volume",
		"Overall output level.", 0.0, 1.0, 0.01, _settings.master_volume, Callable(self, "_fmt_percent"), Callable(self, "_on_master_changed"))
	_master_value = mv["value"]
	var muv: Dictionary = LASettingsWidgets.add_slider(_sections, "Music volume",
		"Generative music level.", 0.0, 1.0, 0.01, _settings.music_volume, Callable(self, "_fmt_percent"), Callable(self, "_on_music_changed"))
	_music_value = muv["value"]
	var sv: Dictionary = LASettingsWidgets.add_slider(_sections, "Sfx volume",
		"Procedural sound-effects level.", 0.0, 1.0, 0.01, _settings.sfx_volume, Callable(self, "_fmt_percent"), Callable(self, "_on_sfx_changed"))
	_sfx_value = sv["value"]

	# --- Controls ---
	LASettingsWidgets.add_header(_sections, "Controls")
	_invert_x_option = LASettingsWidgets.add_option(_sections, "Invert rotate X",
		"Flip the horizontal drag direction when rotating the planet.",
		["Off", "On"], 1 if _settings.invert_rotate_x else 0, Callable(self, "_on_invert_x"))
	_invert_y_option = LASettingsWidgets.add_option(_sections, "Invert rotate Y",
		"Flip the vertical drag direction when rotating the planet.",
		["Off", "On"], 1 if _settings.invert_rotate_y else 0, Callable(self, "_on_invert_y"))


# ---------------------------------------------------------------------------
# Handlers
# ---------------------------------------------------------------------------

func _on_difficulty(preset: int) -> void:
	if _suppress:
		return
	_settings.apply_difficulty_preset(preset as LAGameSettings.Difficulty)
	_refresh_difficulty()


func _on_section_changed() -> void:
	_status_label.text = "Unsaved changes."


func _on_disaster_changed(value: float) -> void:
	_disaster_value.text = _fmt_percent(value)
	if not _suppress:
		_settings.disaster_frequency = value


func _on_climate_changed(value: float) -> void:
	_climate_value.text = _fmt_percent(value)
	if not _suppress:
		_settings.climate_harshness = value


func _on_master_changed(value: float) -> void:
	_master_value.text = _fmt_percent(value)
	if not _suppress:
		_settings.master_volume = value


func _on_music_changed(value: float) -> void:
	_music_value.text = _fmt_percent(value)
	if not _suppress:
		_settings.music_volume = value


func _on_sfx_changed(value: float) -> void:
	_sfx_value.text = _fmt_percent(value)
	if not _suppress:
		_settings.sfx_volume = value


func _on_invert_x(index: int) -> void:
	if _suppress:
		return
	_settings.invert_rotate_x = index == 1
	_on_section_changed()


func _on_invert_y(index: int) -> void:
	if _suppress:
		return
	_settings.invert_rotate_y = index == 1
	_on_section_changed()


func _on_save() -> void:
	var err: int = _settings.save()
	# Broadcast on the application interface — LAVoxelSettingsApplier pushes the knobs into the sim.
	GameMode.apply(_settings)
	print("SETTINGS_SAVED ok=%s %s" % [str(err == OK), _settings.summary()])
	_status_label.text = "Saved." if err == OK else "Save failed (err %d)." % err


func _on_back() -> void:
	var err: int = get_tree().change_scene_to_file(MAIN_MENU_SCENE)
	if err != OK:
		push_error("SettingsMenu: failed to return to main menu (err=%d)" % err)


## Open the model manager as a full-screen overlay; Close frees it.
func _on_models() -> void:
	var overlay: Control = Control.new()
	overlay.name = "ModelManagerOverlay"
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(overlay)

	var panel: Control = ModelManagerPanelScene.instantiate()
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.add_child(panel)
	panel.open()

	var close_button: Button = LAMenuStyle.make_button("Close")
	close_button.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	close_button.offset_left = -140.0
	close_button.offset_top = 12.0
	close_button.offset_right = -16.0
	close_button.custom_minimum_size = Vector2(120.0, 40.0)
	close_button.pressed.connect(overlay.queue_free)
	overlay.add_child(close_button)
	close_button.grab_focus()


# ---------------------------------------------------------------------------
# Refresh helpers
# ---------------------------------------------------------------------------

# Push the difficulty + audio values onto their controls without re-firing the change handlers. The two
# section objects own their own refresh.
func _refresh_difficulty() -> void:
	_suppress = true
	for preset in _difficulty_buttons:
		(_difficulty_buttons[preset] as Button).set_pressed_no_signal(preset == _settings.difficulty)
	_disaster_slider.set_value_no_signal(_settings.disaster_frequency)
	_disaster_value.text = _fmt_percent(_settings.disaster_frequency)
	_climate_slider.set_value_no_signal(_settings.climate_harshness)
	_climate_value.text = _fmt_percent(_settings.climate_harshness)
	_suppress = false


func _add_difficulty(row: HBoxContainer, preset: int, text: String, tooltip: String) -> void:
	_difficulty_buttons[preset] = LASettingsWidgets.add_preset_button(row, text, _difficulty_group, tooltip, Callable(self, "_on_difficulty").bind(preset))


func _fmt_percent(v: float) -> String:
	return "%d%%" % int(round(v * 100.0))


func _has_prefix(args: PackedStringArray, prefix: String) -> bool:
	for a in args:
		if a.begins_with(prefix):
			return true
	return false


# Verification aid: print every control that carries a hover tooltip, then quit. Triggered by
# `--dump-tooltips`.
func _dump_tooltips() -> void:
	var seen: Dictionary = {}
	var count: int = _walk_tooltips(self, seen)
	print("TOOLTIP_COUNT=%d" % count)
	LAAppExit.request(self, 0)


func _walk_tooltips(node: Node, seen: Dictionary) -> int:
	var count: int = 0
	if node is Control:
		var control: Control = node as Control
		var tip: String = control.tooltip_text
		if tip != "" and not seen.has(tip):
			seen[tip] = true
			var label: String = _control_label(control)
			print("TOOLTIP| %s | %s" % [label, tip])
			count += 1
	for child in node.get_children():
		count += _walk_tooltips(child, seen)
	return count


func _control_label(control: Control) -> String:
	if control is Button:
		return "[button] " + (control as Button).text
	if control is Label:
		return "[label] " + (control as Label).text
	if control is OptionButton:
		return "[dropdown]"
	if control is HSlider:
		return "[slider]"
	return control.get_class()
