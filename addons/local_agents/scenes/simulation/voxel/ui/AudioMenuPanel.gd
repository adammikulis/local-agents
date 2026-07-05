class_name LAAudioMenuPanel
extends PanelContainer

## In-code audio control menu for the voxel simulation. Binds the whole procedural
## audio control surface (LocalAgentsAudioDirector) to the UI: music composition
## (scale / progression / key / tempo / time signature / auto / arrangement), a bus
## volume mixer, master/music/sfx enable toggles, and an SFX preview bench.
##
## Presentation only — it drives the audio engine and the AudioServer buses; it never
## reads or writes simulation-authoritative state. Built entirely in code, inheriting
## the shared Theme from the parent HudRoot (see SpawnPaletteHud). No .tscn, no assets.

## Emitted when the "Auto-adapt music (sim mood)" toggle changes. VoxelWorld listens
## and stops/starts feeding its live mood snapshot so manual picks can stick.
signal auto_adapt_changed(on: bool)

# Named audio buses (see audio/default_bus_layout.tres).
const BUSES: PackedStringArray = ["Master", "Music", "Sfx", "Ui"]

const KEY_MIN: int = 33   # A1
const KEY_MAX: int = 57   # A3
const TEMPO_MIN: float = 30.0
const TEMPO_MAX: float = 220.0
const TIME_SIG_MIN: int = 2
const TIME_SIG_MAX: int = 12

# Colors mirror SpawnPaletteHud's palette so the two panels read as one system.
const COL_TEXT: Color = Color(0.90, 0.92, 0.95, 1.0)
const COL_TEXT_DIM: Color = Color(0.62, 0.66, 0.72, 1.0)
const COL_TEXT_HEADING: Color = Color(0.98, 0.99, 1.0, 1.0)
const COL_ACCENT: Color = Color(0.33, 0.70, 0.98, 1.0)
const COL_BORDER: Color = Color(0.24, 0.27, 0.33, 1.0)

var _director: LocalAgentsAudioDirector = null

# Controls we need to read/refresh after bind.
var _mode_option: OptionButton
var _prog_option: OptionButton
var _key_slider: HSlider
var _key_value: Label
var _tempo_slider: HSlider
var _tempo_value: Label
var _timesig_slider: HSlider
var _timesig_value: Label
var _auto_mode_check: CheckButton
var _arrangement_check: CheckButton
var _auto_adapt_check: CheckButton
var _status_label: Label

var _mode_names: PackedStringArray = []
var _prog_names: PackedStringArray = []

var _bus_sliders: Dictionary = {}   # bus name -> HSlider
var _bus_mutes: Dictionary = {}     # bus name -> CheckButton

var _refresh_ticks: int = 0
# Guard so programmatic control updates during bind() don't fire change handlers.
var _suppress_signals: bool = false


func _ready() -> void:
	visible = false
	set_anchors_and_offsets_preset(Control.PRESET_CENTER_LEFT)
	offset_left = 12.0
	offset_top = 0.0
	grow_vertical = Control.GROW_DIRECTION_BOTH
	custom_minimum_size = Vector2(320.0, 0.0)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build()
	set_process(true)


func _process(_delta: float) -> void:
	if not visible:
		return
	_refresh_ticks += 1
	if _refresh_ticks % 30 == 0:
		refresh_status()


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## Wire this panel to the live audio director and initialize all control states.
func bind(director: LocalAgentsAudioDirector) -> void:
	_director = director
	if _director == null:
		return

	_suppress_signals = true

	_mode_names = PackedStringArray()
	_mode_option.clear()
	for mode in _director.list_music_modes():
		_mode_names.append(String(mode))
		_mode_option.add_item(String(mode))

	var descriptions: Dictionary = _director.describe_music_progressions()
	_prog_names = PackedStringArray()
	_prog_option.clear()
	_prog_option.add_item("(Generative)")   # index 0 -> mode-driven harmony
	for prog in _director.list_music_progressions():
		var name: String = String(prog)
		var idx: int = _prog_option.item_count
		_prog_option.add_item(name)
		_prog_names.append(name)
		if descriptions.has(name):
			_prog_option.set_item_tooltip(idx, String(descriptions[name]))

	var status: Dictionary = _director.music_status()
	_select_option_by_text(_mode_option, String(status.get("mode", "")))

	var key_root: int = int(status.get("key_root", KEY_MIN))
	_key_slider.value = clampf(float(key_root), float(KEY_MIN), float(KEY_MAX))
	_update_key_label(int(_key_slider.value))

	var time_sig: int = int(status.get("time_signature", 4))
	_timesig_slider.value = clampf(float(time_sig), float(TIME_SIG_MIN), float(TIME_SIG_MAX))
	_timesig_value.text = "%d / 4" % int(_timesig_slider.value)

	# Tempo isn't in music_status(); leave the slider at its default midpoint and let
	# the user drive it. (Arrangement can still modulate it live.)
	_update_tempo_label(_tempo_slider.value)

	# Initialize bus sliders from current AudioServer state.
	for bus in BUSES:
		var bus_idx: int = AudioServer.get_bus_index(bus)
		if bus_idx < 0:
			continue
		var slider: HSlider = _bus_sliders.get(bus, null)
		var mute: CheckButton = _bus_mutes.get(bus, null)
		if slider != null:
			slider.value = clampf(db_to_linear(AudioServer.get_bus_volume_db(bus_idx)), 0.0, 1.0)
		if mute != null:
			mute.button_pressed = AudioServer.is_bus_mute(bus_idx)

	_suppress_signals = false
	refresh_status()


## Refresh the live status readout (mode / key / time-sig / section).
func refresh_status() -> void:
	if _director == null or _status_label == null:
		return
	var status: Dictionary = _director.music_status()
	if status.is_empty():
		_status_label.text = "(music engine unavailable)"
		return
	var enabled: bool = bool(status.get("enabled", false))
	var mode: String = String(status.get("mode", "?"))
	var key_root: int = int(status.get("key_root", 0))
	var time_sig: int = int(status.get("time_signature", 4))
	var section: String = String(status.get("section", "-"))
	_status_label.text = "%s\nmode: %s   key: %s\n%d/4   section: %s" % [
		("playing" if enabled else "stopped"),
		mode, _midi_name(key_root), time_sig, section,
	]


# ---------------------------------------------------------------------------
# Construction
# ---------------------------------------------------------------------------

func _build() -> void:
	var margin: MarginContainer = MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 14)
	margin.add_theme_constant_override("margin_right", 14)
	margin.add_theme_constant_override("margin_top", 12)
	margin.add_theme_constant_override("margin_bottom", 12)
	add_child(margin)

	var scroll: ScrollContainer = ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.custom_minimum_size = Vector2(292.0, 460.0)
	margin.add_child(scroll)

	var col: VBoxContainer = VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(col)

	_add_heading(col, "AUDIO")

	# --- Enable toggles ---
	_add_section_title(col, "Output")
	var enable_all: CheckButton = _add_check(col, "Audio enabled", true)
	enable_all.toggled.connect(func(on: bool) -> void:
		if not _suppress_signals and _director != null:
			_director.set_enabled(on))
	var enable_music: CheckButton = _add_check(col, "Music enabled", true)
	enable_music.toggled.connect(func(on: bool) -> void:
		if not _suppress_signals and _director != null:
			_director.set_music_enabled(on))
	var enable_sfx: CheckButton = _add_check(col, "SFX enabled", true)
	enable_sfx.toggled.connect(func(on: bool) -> void:
		if not _suppress_signals and _director != null:
			_director.set_sfx_enabled(on))

	# --- Music composition ---
	_add_section_title(col, "Music")

	_mode_option = _add_option(col, "Scale / mode")
	_mode_option.item_selected.connect(_on_mode_selected)

	_prog_option = _add_option(col, "Progression")
	_prog_option.item_selected.connect(_on_progression_selected)

	var key_row: Dictionary = _add_slider(col, "Key", float(KEY_MIN), float(KEY_MAX), 1.0, float(KEY_MIN))
	_key_slider = key_row["slider"]
	_key_value = key_row["value"]
	_key_slider.value_changed.connect(_on_key_changed)

	var tempo_row: Dictionary = _add_slider(col, "Tempo", TEMPO_MIN, TEMPO_MAX, 1.0, 84.0)
	_tempo_slider = tempo_row["slider"]
	_tempo_value = tempo_row["value"]
	_tempo_slider.value_changed.connect(_on_tempo_changed)

	var ts_row: Dictionary = _add_slider(col, "Time sig", float(TIME_SIG_MIN), float(TIME_SIG_MAX), 1.0, 4.0)
	_timesig_slider = ts_row["slider"]
	_timesig_value = ts_row["value"]
	_timesig_slider.value_changed.connect(_on_timesig_changed)

	_auto_mode_check = _add_check(col, "Engine auto-mode", false)
	_auto_mode_check.tooltip_text = "Let the engine pick the scale from mood/time-of-day"
	_auto_mode_check.toggled.connect(func(on: bool) -> void:
		if not _suppress_signals and _director != null:
			_director.set_music_auto(on))

	_arrangement_check = _add_check(col, "Long-form arrangement", true)
	_arrangement_check.tooltip_text = "Multi-section song structure (may modulate key/tempo/meter)"
	_arrangement_check.toggled.connect(func(on: bool) -> void:
		if not _suppress_signals and _director != null:
			_director.set_music_arrangement_enabled(on))

	_auto_adapt_check = _add_check(col, "Auto-adapt to sim", true)
	_auto_adapt_check.tooltip_text = "Feed live sim mood to the music. Turn off so your manual picks stick."
	_auto_adapt_check.toggled.connect(func(on: bool) -> void:
		if not _suppress_signals:
			auto_adapt_changed.emit(on))

	_status_label = Label.new()
	_status_label.add_theme_color_override("font_color", COL_TEXT_DIM)
	_status_label.add_theme_font_size_override("font_size", 12)
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status_label.text = "(no status)"
	col.add_child(_status_label)

	# --- Volume mixer ---
	_add_section_title(col, "Mixer")
	for bus in BUSES:
		_add_bus_row(col, bus)

	# --- SFX bench ---
	_add_section_title(col, "SFX bench")
	_build_sfx_bench(col)


func _build_sfx_bench(col: VBoxContainer) -> void:
	var grid: GridContainer = GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 6)
	grid.add_theme_constant_override("v_separation", 6)
	col.add_child(grid)

	# sfx_keys() needs the director; when not yet bound, fall back to a static preset list.
	var keys: Array = []
	if _director != null:
		keys = _director.sfx_keys()
	if keys.is_empty():
		keys = LocalAgentsSynthPresets.sfx_presets().keys()
	keys.sort()
	for key in keys:
		var btn: Button = Button.new()
		btn.text = String(key)
		btn.focus_mode = Control.FOCUS_NONE
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.add_theme_font_size_override("font_size", 12)
		var sfx_key: String = String(key)
		btn.pressed.connect(func() -> void:
			if _director != null:
				# Non-positional preview (omit world position).
				_director.play_sfx(sfx_key))
		grid.add_child(btn)


func _add_bus_row(col: VBoxContainer, bus: String) -> void:
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	col.add_child(row)

	var label: Label = Label.new()
	label.text = bus
	label.custom_minimum_size = Vector2(52.0, 0.0)
	label.add_theme_color_override("font_color", COL_TEXT)
	label.add_theme_font_size_override("font_size", 13)
	row.add_child(label)

	var slider: HSlider = HSlider.new()
	slider.min_value = 0.0
	slider.max_value = 1.0
	slider.step = 0.01
	slider.value = 1.0
	slider.custom_minimum_size = Vector2(150.0, 0.0)
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	slider.value_changed.connect(func(v: float) -> void:
		if _suppress_signals:
			return
		var idx: int = AudioServer.get_bus_index(bus)
		if idx >= 0:
			AudioServer.set_bus_volume_db(idx, linear_to_db(v) if v > 0.0 else -80.0))
	row.add_child(slider)
	_bus_sliders[bus] = slider

	var mute: CheckButton = CheckButton.new()
	mute.tooltip_text = "Mute %s" % bus
	mute.focus_mode = Control.FOCUS_NONE
	mute.toggled.connect(func(on: bool) -> void:
		if _suppress_signals:
			return
		var idx: int = AudioServer.get_bus_index(bus)
		if idx >= 0:
			AudioServer.set_bus_mute(idx, on))
	row.add_child(mute)
	_bus_mutes[bus] = mute


# ---------------------------------------------------------------------------
# Handlers
# ---------------------------------------------------------------------------

func _on_mode_selected(index: int) -> void:
	if _suppress_signals or _director == null:
		return
	if index < 0 or index >= _mode_names.size():
		return
	_director.set_music_mode(_mode_names[index])
	# Selecting a mode switches harmony to generative — reflect that in the progression box.
	_suppress_signals = true
	_prog_option.select(0)
	_suppress_signals = false
	refresh_status()


func _on_progression_selected(index: int) -> void:
	if _suppress_signals or _director == null:
		return
	if index == 0:
		# "(Generative)" -> re-apply the currently selected mode.
		var mi: int = _mode_option.selected
		if mi >= 0 and mi < _mode_names.size():
			_director.set_music_mode(_mode_names[mi])
	else:
		var pi: int = index - 1
		if pi >= 0 and pi < _prog_names.size():
			_director.set_music_progression(_prog_names[pi])
	refresh_status()


func _on_key_changed(value: float) -> void:
	_update_key_label(int(value))
	if not _suppress_signals and _director != null:
		_director.set_music_key(int(value))


func _on_tempo_changed(value: float) -> void:
	_update_tempo_label(value)
	if not _suppress_signals and _director != null:
		_director.set_music_tempo(value)


func _on_timesig_changed(value: float) -> void:
	_timesig_value.text = "%d / 4" % int(value)
	if not _suppress_signals and _director != null:
		_director.set_music_time_signature(int(value))


# ---------------------------------------------------------------------------
# Widget helpers
# ---------------------------------------------------------------------------

func _add_heading(col: VBoxContainer, text: String) -> void:
	var l: Label = Label.new()
	l.text = text
	l.add_theme_color_override("font_color", COL_ACCENT)
	l.add_theme_font_size_override("font_size", 16)
	col.add_child(l)


func _add_section_title(col: VBoxContainer, text: String) -> void:
	var rule: ColorRect = ColorRect.new()
	rule.color = COL_BORDER
	rule.custom_minimum_size = Vector2(0.0, 1.0)
	rule.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_child(rule)
	var l: Label = Label.new()
	l.text = text
	l.add_theme_color_override("font_color", COL_TEXT_HEADING)
	l.add_theme_font_size_override("font_size", 13)
	col.add_child(l)


func _add_check(col: VBoxContainer, text: String, initial: bool) -> CheckButton:
	var c: CheckButton = CheckButton.new()
	c.text = text
	c.button_pressed = initial
	c.focus_mode = Control.FOCUS_NONE
	c.add_theme_font_size_override("font_size", 13)
	col.add_child(c)
	return c


func _add_option(col: VBoxContainer, label_text: String) -> OptionButton:
	var l: Label = Label.new()
	l.text = label_text
	l.add_theme_color_override("font_color", COL_TEXT_DIM)
	l.add_theme_font_size_override("font_size", 12)
	col.add_child(l)
	var opt: OptionButton = OptionButton.new()
	opt.focus_mode = Control.FOCUS_NONE
	opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	opt.add_theme_font_size_override("font_size", 13)
	col.add_child(opt)
	return opt


## Returns {"slider": HSlider, "value": Label}. A label + [slider ---- value] row.
func _add_slider(col: VBoxContainer, label_text: String, mn: float, mx: float, step: float, initial: float) -> Dictionary:
	var l: Label = Label.new()
	l.text = label_text
	l.add_theme_color_override("font_color", COL_TEXT_DIM)
	l.add_theme_font_size_override("font_size", 12)
	col.add_child(l)

	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	col.add_child(row)

	var slider: HSlider = HSlider.new()
	slider.min_value = mn
	slider.max_value = mx
	slider.step = step
	slider.value = initial
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(slider)

	var value: Label = Label.new()
	value.text = str(int(initial))
	value.add_theme_color_override("font_color", COL_TEXT)
	value.add_theme_font_size_override("font_size", 13)
	value.custom_minimum_size = Vector2(56.0, 0.0)
	value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(value)

	return {"slider": slider, "value": value}


func _update_key_label(midi: int) -> void:
	if _key_value != null:
		_key_value.text = _midi_name(midi)


func _update_tempo_label(bpm: float) -> void:
	if _tempo_value != null:
		_tempo_value.text = "%d bpm" % int(bpm)


func _select_option_by_text(opt: OptionButton, text: String) -> void:
	if text.is_empty():
		return
	for i in opt.item_count:
		if opt.get_item_text(i) == text:
			opt.select(i)
			return


func _midi_name(midi: int) -> String:
	# Prefer the engine's canonical naming; fall back to a local table.
	if midi <= 0:
		return "-"
	var names: PackedStringArray = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
	var octave: int = int(midi / 12) - 1
	var name: String = names[midi % 12]
	return "%s%d" % [name, octave]
