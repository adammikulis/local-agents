class_name LASettingsMenu
extends Control


const MAIN_MENU_SCENE: String = "res://addons/local_agents/game/menu/MainMenu.tscn"

var _settings: LAGameSettings = null

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
	_models_button.pressed.connect(func() -> void: LAMenuStyle.open_model_manager(self))
	_back_button.pressed.connect(_on_back)
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
	_graphics = LAGraphicsSettingsSection.new()
	_graphics.setup(_settings, Callable(self, "_on_section_changed"))
	_graphics.build(_sections)

	_sim = LASimSettingsSection.new()
	_sim.setup(_settings, Callable(self, "_on_section_changed"))
	_sim.build(_sections)

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

func _on_section_changed() -> void:
	_status_label.text = "Unsaved changes."


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


# ---------------------------------------------------------------------------
# Refresh helpers
# ---------------------------------------------------------------------------

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
