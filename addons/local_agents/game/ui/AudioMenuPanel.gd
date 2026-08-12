class_name LAAudioMenuPanel
extends PanelContainer


signal auto_adapt_changed(on: bool)

# One mixer row per audio aspect. `bus` is the AudioServer bus it rides; `flag` names the director
# synthesis toggle a mute should also flip ("" = bus-only); `node` is its row in the scene.
const ASPECTS: Array = [
	{"label": "Master", "bus": "Master", "flag": "master", "node": "MasterRow"},
	{"label": "Music", "bus": "Music", "flag": "music", "node": "MusicRow"},
	{"label": "SFX", "bus": "Sfx", "flag": "sfx", "node": "SfxRow"},
	{"label": "Voice", "bus": "Voice", "flag": "", "node": "VoiceRow"},
	{"label": "UI", "bus": "Ui", "flag": "", "node": "UiRow"},
]

const KEY_MIN: int = 33   # A1
const KEY_MAX: int = 57   # A3
const TIME_SIG_MIN: int = 2
const TIME_SIG_MAX: int = 12

@onready var _col: VBoxContainer = $Margin/Scroll/Col
@onready var _mode_option: OptionButton = $Margin/Scroll/Col/ModeOption
@onready var _prog_option: OptionButton = $Margin/Scroll/Col/ProgOption
@onready var _key_slider: HSlider = $Margin/Scroll/Col/KeyRow/Slider
@onready var _key_value: Label = $Margin/Scroll/Col/KeyRow/Value
@onready var _tempo_slider: HSlider = $Margin/Scroll/Col/TempoRow/Slider
@onready var _tempo_value: Label = $Margin/Scroll/Col/TempoRow/Value
@onready var _timesig_slider: HSlider = $Margin/Scroll/Col/TimeSigRow/Slider
@onready var _timesig_value: Label = $Margin/Scroll/Col/TimeSigRow/Value
@onready var _auto_mode_check: CheckButton = $Margin/Scroll/Col/AutoMode
@onready var _arrangement_check: CheckButton = $Margin/Scroll/Col/Arrangement
@onready var _auto_adapt_check: CheckButton = $Margin/Scroll/Col/AutoAdapt
@onready var _status_label: Label = $Margin/Scroll/Col/Status
@onready var _sfx_grid: GridContainer = $Margin/Scroll/Col/SfxGrid

var _director: LAAudioDirector = null

var _mode_names: PackedStringArray = []
var _prog_names: PackedStringArray = []

var _bus_sliders: Dictionary = {}   # bus name -> HSlider
var _bus_mutes: Dictionary = {}     # bus name -> CheckButton

var _refresh_ticks: int = 0
# Guard so programmatic control updates during bind() don't fire change handlers.
var _suppress_signals: bool = false


func _ready() -> void:
	for aspect in ASPECTS:
		_wire_aspect_row(aspect)

	_mode_option.item_selected.connect(_on_mode_selected)
	_prog_option.item_selected.connect(_on_progression_selected)
	_key_slider.value_changed.connect(_on_key_changed)
	_tempo_slider.value_changed.connect(_on_tempo_changed)
	_timesig_slider.value_changed.connect(_on_timesig_changed)

	_auto_mode_check.toggled.connect(func(on: bool) -> void:
		if not _suppress_signals and _director != null:
			_director.set_music_auto(on))
	_arrangement_check.toggled.connect(func(on: bool) -> void:
		if not _suppress_signals and _director != null:
			_director.set_music_arrangement_enabled(on))
	_auto_adapt_check.toggled.connect(func(on: bool) -> void:
		if not _suppress_signals:
			auto_adapt_changed.emit(on))

	_fill_sfx_bench()
	set_process(true)


func _process(_delta: float) -> void:
	if not visible:
		return
	_refresh_ticks += 1
	if _refresh_ticks % 30 == 0:
		refresh_status()


## Wire this panel to the live audio director and initialize all control states.
func bind(director: LAAudioDirector) -> void:
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

	# Tempo isn't in music_status(); leave the slider where it is and let the user drive it.
	_update_tempo_label(_tempo_slider.value)

	# Initialize every mixer row's slider (volume) + mute from current AudioServer bus state.
	for aspect in ASPECTS:
		var bus: String = String(aspect["bus"])
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
# Wiring
# ---------------------------------------------------------------------------

func _wire_aspect_row(aspect: Dictionary) -> void:
	var row: HBoxContainer = _col.get_node_or_null(String(aspect["node"])) as HBoxContainer
	if row == null:
		return
	var bus: String = String(aspect["bus"])
	var flag: String = String(aspect["flag"])

	var slider: HSlider = row.get_node_or_null("Slider") as HSlider
	if slider != null:
		slider.value_changed.connect(func(v: float) -> void:
			if _suppress_signals:
				return
			var idx: int = AudioServer.get_bus_index(bus)
			if idx >= 0:
				AudioServer.set_bus_volume_db(idx, linear_to_db(v) if v > 0.0 else -80.0))
		_bus_sliders[bus] = slider

	var mute: CheckButton = row.get_node_or_null("Mute") as CheckButton
	if mute != null:
		mute.toggled.connect(func(on: bool) -> void:
			_on_aspect_mute(bus, flag, on))
		_bus_mutes[bus] = mute


# The preview bench is one button per SFX key, and the key set comes from the director (or the preset
# table before one is bound), so the buttons are made here rather than declared in the scene.
func _fill_sfx_bench() -> void:
	var keys: Array = []
	if _director != null:
		keys = _director.sfx_keys()
	if keys.is_empty():
		keys = LocalAgentSynthPresets.sfx_presets().keys()
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
		_sfx_grid.add_child(btn)


# Mute/unmute an aspect: silence its bus and, if it has a director synthesis flag, stop/start that
# work too — so a muted aspect is both inaudible and not being generated.
func _on_aspect_mute(bus: String, flag: String, on: bool) -> void:
	if _suppress_signals:
		return
	var idx: int = AudioServer.get_bus_index(bus)
	if idx >= 0:
		AudioServer.set_bus_mute(idx, on)
	if _director != null:
		match flag:
			"master": _director.set_enabled(not on)
			"music": _director.set_music_enabled(not on)
			"sfx": _director.set_sfx_enabled(not on)


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
# Label helpers
# ---------------------------------------------------------------------------

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
	if midi <= 0:
		return "-"
	var names: PackedStringArray = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
	var octave: int = int(midi / 12) - 1
	var name: String = names[midi % 12]
	return "%s%d" % [name, octave]
