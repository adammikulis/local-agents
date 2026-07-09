class_name LASettingsMenu
extends Control

## LASettingsMenu — the settings screen. It edits the live LAGameSettings held on the GameMode
## autoload, in three groups:
##   - Difficulty : a Peaceful / Normal / Harsh preset row (seeds the two knobs below) plus the two
##                  continuous sliders — disaster frequency and climate harshness.
##   - Quality    : a Low / Medium / High preset row that maps to concrete perf budgets (grid
##                  resolution, actor budget, effects level), shown as a read-only summary so weak
##                  GPUs can see what they are getting.
##   - Audio      : master / music / sfx volume sliders (linear 0..1).
##
## "Save" persists the resource to user:// (ConfigFile) AND calls GameMode.apply(settings) to broadcast
## it on the settings_applied signal — the defined application interface. This screen NEVER reaches into
## the sim's disaster/spawn/grid code; applying the values to those systems is a later task that connects
## to that signal. "Back" returns to the main menu. Built in code to match the shared menu styling
## (LAMenuStyle); keyboard-navigable. (Explicit types only — no ':=' inferred typing.)

const MAIN_MENU_SCENE: String = "res://addons/local_agents/scenes/menu/MainMenu.tscn"
const ModelManagerPanelScript: GDScript = preload("res://addons/local_agents/ui/ModelManagerPanel.gd")

var _settings: LAGameSettings = null

var _difficulty_group: ButtonGroup = null
var _quality_group: ButtonGroup = null
var _difficulty_buttons: Dictionary = {}   # Difficulty enum -> Button
var _quality_buttons: Dictionary = {}      # Quality enum -> Button
var _quality_summary: Label = null
var _status_label: Label = null

var _disaster_value: Label = null
var _climate_value: Label = null
var _master_value: Label = null
var _music_value: Label = null
var _sfx_value: Label = null

var _suppress: bool = false


func _ready() -> void:
	_settings = GameMode.settings
	if _settings == null:
		_settings = LAGameSettings.load_or_default()
		GameMode.settings = _settings
	_build_ui()
	add_child(LAMenuShooter.new())


func _build_ui() -> void:
	var bg: ColorRect = ColorRect.new()
	bg.color = LAMenuStyle.OVERLAY_BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	var center: CenterContainer = CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var panel: PanelContainer = PanelContainer.new()
	panel.add_theme_stylebox_override("panel", LAMenuStyle.panel_style())
	center.add_child(panel)

	var scroll: ScrollContainer = ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.custom_minimum_size = Vector2(440.0, 560.0)
	panel.add_child(scroll)

	var vbox: VBoxContainer = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	vbox.custom_minimum_size = Vector2(420.0, 0.0)
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(vbox)

	vbox.add_child(LAMenuStyle.make_title("Settings"))

	# --- Difficulty ---
	_add_section(vbox, "Difficulty")
	_difficulty_group = ButtonGroup.new()
	var diff_row: HBoxContainer = _add_button_row(vbox)
	_difficulty_buttons[LAGameSettings.Difficulty.PEACEFUL] = _add_preset_button(diff_row, "Peaceful", _difficulty_group, _on_difficulty.bind(LAGameSettings.Difficulty.PEACEFUL))
	_difficulty_buttons[LAGameSettings.Difficulty.NORMAL] = _add_preset_button(diff_row, "Normal", _difficulty_group, _on_difficulty.bind(LAGameSettings.Difficulty.NORMAL))
	_difficulty_buttons[LAGameSettings.Difficulty.HARSH] = _add_preset_button(diff_row, "Harsh", _difficulty_group, _on_difficulty.bind(LAGameSettings.Difficulty.HARSH))

	_disaster_value = _add_slider(vbox, "Disaster frequency", _settings.disaster_frequency, _on_disaster_changed)
	_climate_value = _add_slider(vbox, "Climate harshness", _settings.climate_harshness, _on_climate_changed)

	# --- Quality / performance ---
	_add_section(vbox, "Quality / performance")
	_quality_group = ButtonGroup.new()
	var qual_row: HBoxContainer = _add_button_row(vbox)
	_quality_buttons[LAGameSettings.Quality.LOW] = _add_preset_button(qual_row, "Low", _quality_group, _on_quality.bind(LAGameSettings.Quality.LOW))
	_quality_buttons[LAGameSettings.Quality.MEDIUM] = _add_preset_button(qual_row, "Medium", _quality_group, _on_quality.bind(LAGameSettings.Quality.MEDIUM))
	_quality_buttons[LAGameSettings.Quality.HIGH] = _add_preset_button(qual_row, "High", _quality_group, _on_quality.bind(LAGameSettings.Quality.HIGH))
	_quality_summary = LAMenuStyle.make_caption("")
	_quality_summary.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	vbox.add_child(_quality_summary)

	# --- Audio ---
	_add_section(vbox, "Audio")
	_master_value = _add_slider(vbox, "Master volume", _settings.master_volume, _on_master_changed)
	_music_value = _add_slider(vbox, "Music volume", _settings.music_volume, _on_music_changed)
	_sfx_value = _add_slider(vbox, "Sfx volume", _settings.sfx_volume, _on_sfx_changed)

	# --- Actions ---
	var spacer: Control = Control.new()
	spacer.custom_minimum_size = Vector2(0.0, 8.0)
	vbox.add_child(spacer)

	var actions: HBoxContainer = _add_button_row(vbox)
	var save_button: Button = LAMenuStyle.make_button("Save")
	save_button.custom_minimum_size = Vector2(0.0, 44.0)
	save_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	save_button.pressed.connect(_on_save)
	actions.add_child(save_button)

	var models_button: Button = LAMenuStyle.make_button("Models")
	models_button.custom_minimum_size = Vector2(0.0, 44.0)
	models_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	models_button.tooltip_text = "Download / pick the local LLMs that drive creatures + the streamer"
	models_button.pressed.connect(_on_models)
	actions.add_child(models_button)

	var back_button: Button = LAMenuStyle.make_button("Back")
	back_button.custom_minimum_size = Vector2(0.0, 44.0)
	back_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	back_button.pressed.connect(_on_back)
	actions.add_child(back_button)

	_status_label = LAMenuStyle.make_caption("")
	vbox.add_child(_status_label)

	_refresh_from_settings()
	save_button.grab_focus()


# ---------------------------------------------------------------------------
# Handlers
# ---------------------------------------------------------------------------

func _on_difficulty(preset: int) -> void:
	if _suppress:
		return
	_settings.apply_difficulty_preset(preset as LAGameSettings.Difficulty)
	_refresh_from_settings()


func _on_quality(preset: int) -> void:
	if _suppress:
		return
	_settings.apply_quality_preset(preset as LAGameSettings.Quality)
	_refresh_from_settings()


func _on_disaster_changed(value: float) -> void:
	_disaster_value.text = "%d%%" % int(round(value * 100.0))
	if not _suppress:
		_settings.disaster_frequency = value


func _on_climate_changed(value: float) -> void:
	_climate_value.text = "%d%%" % int(round(value * 100.0))
	if not _suppress:
		_settings.climate_harshness = value


func _on_master_changed(value: float) -> void:
	_master_value.text = "%d%%" % int(round(value * 100.0))
	if not _suppress:
		_settings.master_volume = value


func _on_music_changed(value: float) -> void:
	_music_value.text = "%d%%" % int(round(value * 100.0))
	if not _suppress:
		_settings.music_volume = value


func _on_sfx_changed(value: float) -> void:
	_sfx_value.text = "%d%%" % int(round(value * 100.0))
	if not _suppress:
		_settings.sfx_volume = value


func _on_save() -> void:
	var err: int = _settings.save()
	# Broadcast on the defined application interface (the sim connects here later).
	GameMode.apply(_settings)
	print("SETTINGS_SAVED ok=%s %s" % [str(err == OK), _settings.summary()])
	if _status_label != null:
		_status_label.text = "Saved." if err == OK else "Save failed (err %d)." % err


func _on_back() -> void:
	var err: int = get_tree().change_scene_to_file(MAIN_MENU_SCENE)
	if err != OK:
		push_error("SettingsMenu: failed to return to main menu (err=%d)" % err)


## Open the in-game model manager as a full-screen overlay (no scene switch — Close frees it).
func _on_models() -> void:
	var overlay: Control = Control.new()
	overlay.name = "ModelManagerOverlay"
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(overlay)

	var panel: Control = ModelManagerPanelScript.new()
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
# Refresh + widget helpers
# ---------------------------------------------------------------------------

# Push the resource values onto every control without re-firing the change handlers.
func _refresh_from_settings() -> void:
	_suppress = true
	for preset in _difficulty_buttons:
		(_difficulty_buttons[preset] as Button).set_pressed_no_signal(preset == _settings.difficulty)
	for preset in _quality_buttons:
		(_quality_buttons[preset] as Button).set_pressed_no_signal(preset == _settings.quality)
	if _quality_summary != null:
		_quality_summary.text = "Grid %d³  ·  actors %d  ·  effects %s" % [
			_settings.grid_resolution, _settings.actor_budget, _effects_name(_settings.effects_level),
		]
	_disaster_value.text = "%d%%" % int(round(_settings.disaster_frequency * 100.0))
	_climate_value.text = "%d%%" % int(round(_settings.climate_harshness * 100.0))
	_master_value.text = "%d%%" % int(round(_settings.master_volume * 100.0))
	_music_value.text = "%d%%" % int(round(_settings.music_volume * 100.0))
	_sfx_value.text = "%d%%" % int(round(_settings.sfx_volume * 100.0))
	_sync_slider("Disaster frequency", _settings.disaster_frequency)
	_sync_slider("Climate harshness", _settings.climate_harshness)
	_suppress = false


func _effects_name(level: int) -> String:
	match level:
		LAGameSettings.EffectsLevel.LOW: return "low"
		LAGameSettings.EffectsLevel.HIGH: return "high"
		_: return "medium"


func _add_section(col: VBoxContainer, text: String) -> void:
	var rule: ColorRect = ColorRect.new()
	rule.color = LAMenuStyle.ACCENT
	rule.color.a = 0.35
	rule.custom_minimum_size = Vector2(0.0, 1.0)
	rule.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_child(rule)
	var label: Label = Label.new()
	label.text = text
	label.add_theme_color_override("font_color", LAMenuStyle.ACCENT)
	label.add_theme_font_size_override("font_size", 16)
	col.add_child(label)


func _add_button_row(col: VBoxContainer) -> HBoxContainer:
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	col.add_child(row)
	return row


func _add_preset_button(row: HBoxContainer, text: String, group: ButtonGroup, cb: Callable) -> Button:
	var button: Button = Button.new()
	button.text = text
	button.toggle_mode = true
	button.button_group = group
	button.focus_mode = Control.FOCUS_ALL
	button.custom_minimum_size = Vector2(0.0, 38.0)
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.pressed.connect(cb)
	row.add_child(button)
	return button


# A labelled 0..1 slider row: [caption ........ value] then the slider. Returns the value Label.
# The slider's value_changed drives `cb`; the returned label shows the percentage.
func _add_slider(col: VBoxContainer, label_text: String, initial: float, cb: Callable) -> Label:
	var header: HBoxContainer = HBoxContainer.new()
	col.add_child(header)
	var caption: Label = Label.new()
	caption.text = label_text
	caption.add_theme_color_override("font_color", LAMenuStyle.TEXT_DIM)
	caption.add_theme_font_size_override("font_size", 13)
	caption.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(caption)
	var value: Label = Label.new()
	value.text = "%d%%" % int(round(initial * 100.0))
	value.add_theme_color_override("font_color", LAMenuStyle.TEXT)
	value.add_theme_font_size_override("font_size", 13)
	value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	value.custom_minimum_size = Vector2(52.0, 0.0)
	header.add_child(value)

	var slider: HSlider = HSlider.new()
	slider.name = _slider_node_name(label_text)
	slider.min_value = 0.0
	slider.max_value = 1.0
	slider.step = 0.01
	slider.value = initial
	slider.focus_mode = Control.FOCUS_ALL
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.value_changed.connect(cb)
	col.add_child(slider)
	return value


func _slider_node_name(label_text: String) -> String:
	return "slider_" + label_text.to_lower().replace(" ", "_")


# Reflect a value back onto its slider (used after a preset changes the underlying knobs).
func _sync_slider(label_text: String, value: float) -> void:
	var slider: HSlider = find_child(_slider_node_name(label_text), true, false) as HSlider
	if slider != null:
		slider.set_value_no_signal(value)
