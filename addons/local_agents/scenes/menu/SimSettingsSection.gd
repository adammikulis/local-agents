class_name LASimSettingsSection
extends RefCounted

## LASimSettingsSection — the SIMULATION / AI (CPU-bound) category of the settings screen, kept SEPARATE
## from the GPU graphics category so a player can raise world detail without paying GPU cost, or vice versa.
## It draws its own four-step overall preset row (Low / Medium / High / Ultra) plus the individual CPU knobs
## those presets map to: creature population budget, AI/cognition tick rate, LLM call cadence and field
## update cadence. Picking a preset sets every knob; nudging any individual knob re-derives the preset
## (falling to "Custom" when the knobs no longer match). Every control carries a tooltip naming what it
## affects and that the cost is on the CPU. Numeric knobs show a live value readout.
##
## It edits an LAGameSettings in place and calls `on_changed` after every edit. Built from LASettingsWidgets
## so it shares the menu's control styling. (Explicit types only — no ':=' inferred typing.)

const CUSTOM_LABEL: String = "Custom (individual settings)"

var _settings: LAGameSettings = null
var _on_changed: Callable = Callable()
var _suppress: bool = false

var _preset_group: ButtonGroup = null
var _preset_buttons: Dictionary = {}     # SimPreset -> Button
var _preset_caption: Label = null

var _pop_slider: HSlider = null
var _pop_value: Label = null
var _ai_slider: HSlider = null
var _ai_value: Label = null
var _llm_slider: HSlider = null
var _llm_value: Label = null
var _field_slider: HSlider = null
var _field_value: Label = null


func setup(settings: LAGameSettings, on_changed: Callable) -> void:
	_settings = settings
	_on_changed = on_changed


func build(col: VBoxContainer) -> void:
	LASettingsWidgets.add_header(col, "Simulation / AI — CPU")

	_preset_group = ButtonGroup.new()
	var row: HBoxContainer = LASettingsWidgets.add_row(col)
	_add_preset(row, LAGameSettings.SimPreset.LOW, "Low", "Light CPU — small population, creatures think rarely, field steps sparsely. CPU cost: low.")
	_add_preset(row, LAGameSettings.SimPreset.MEDIUM, "Medium", "Balanced default — a healthy population thinking a few times a second, field every frame. CPU cost: moderate.")
	_add_preset(row, LAGameSettings.SimPreset.HIGH, "High", "Busy world — larger population, more frequent thinking and LLM calls. CPU cost: high.")
	_add_preset(row, LAGameSettings.SimPreset.ULTRA, "Ultra", "Maximum — largest population, every-frame thinking, most frequent LLM calls. CPU cost: highest.")

	_preset_caption = LAMenuStyle.make_caption("")
	_preset_caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	col.add_child(_preset_caption)

	# --- Individual CPU knobs ---
	var pop: Dictionary = LASettingsWidgets.add_slider(col, "Population budget",
		"Maximum concurrent creatures — every creature runs cognition and movement. CPU cost: high.",
		20.0, 480.0, 10.0, float(_settings.actor_budget), Callable(self, "_fmt_int"), Callable(self, "_on_pop"))
	_pop_slider = pop["slider"]
	_pop_value = pop["value"]

	var ai: Dictionary = LASettingsWidgets.add_slider(col, "AI tick rate",
		"How often creatures re-decide — every N frames. Fewer frames = smarter but heavier. CPU cost: high.",
		1.0, 12.0, 1.0, float(_settings.ai_tick_frames), Callable(self, "_fmt_every_frames"), Callable(self, "_on_ai"))
	_ai_slider = ai["slider"]
	_ai_value = ai["value"]

	var llm: Dictionary = LASettingsWidgets.add_slider(col, "LLM call cadence",
		"Seconds between local-LLM cognition / narration calls. Shorter = livelier but heavier. CPU cost: very high.",
		2.0, 40.0, 1.0, _settings.llm_cadence, Callable(self, "_fmt_seconds"), Callable(self, "_on_llm"))
	_llm_slider = llm["slider"]
	_llm_value = llm["value"]

	var field: Dictionary = LASettingsWidgets.add_slider(col, "Field update cadence",
		"How often the world substrate (water / heat / air / fire) steps — every N frames. CPU cost: high.",
		1.0, 6.0, 1.0, float(_settings.field_cadence), Callable(self, "_fmt_every_frames"), Callable(self, "_on_field"))
	_field_slider = field["slider"]
	_field_value = field["value"]

	refresh()


# ---------------------------------------------------------------------------
# Handlers
# ---------------------------------------------------------------------------

func _on_preset(preset: int) -> void:
	if _suppress:
		return
	_settings.apply_sim_preset(preset as LAGameSettings.SimPreset)
	refresh()
	_notify()


func _on_pop(value: float) -> void:
	_pop_value.text = _fmt_int(value)
	if _suppress:
		return
	_settings.actor_budget = int(round(value))
	_after_individual()


func _on_ai(value: float) -> void:
	_ai_value.text = _fmt_every_frames(value)
	if _suppress:
		return
	_settings.ai_tick_frames = int(round(value))
	_after_individual()


func _on_llm(value: float) -> void:
	_llm_value.text = _fmt_seconds(value)
	if _suppress:
		return
	_settings.llm_cadence = value
	_after_individual()


func _on_field(value: float) -> void:
	_field_value.text = _fmt_every_frames(value)
	if _suppress:
		return
	_settings.field_cadence = int(round(value))
	_after_individual()


func _after_individual() -> void:
	_settings.resolve_sim_preset()
	_refresh_preset_highlight()
	_notify()


func _notify() -> void:
	if _on_changed.is_valid():
		_on_changed.call()


# ---------------------------------------------------------------------------
# Refresh
# ---------------------------------------------------------------------------

func refresh() -> void:
	_suppress = true
	_pop_slider.set_value_no_signal(float(_settings.actor_budget))
	_pop_value.text = _fmt_int(float(_settings.actor_budget))
	_ai_slider.set_value_no_signal(float(_settings.ai_tick_frames))
	_ai_value.text = _fmt_every_frames(float(_settings.ai_tick_frames))
	_llm_slider.set_value_no_signal(_settings.llm_cadence)
	_llm_value.text = _fmt_seconds(_settings.llm_cadence)
	_field_slider.set_value_no_signal(float(_settings.field_cadence))
	_field_value.text = _fmt_every_frames(float(_settings.field_cadence))
	_refresh_preset_highlight()
	_suppress = false


func _refresh_preset_highlight() -> void:
	var active: int = int(_settings.sim_preset)
	for preset in _preset_buttons:
		(_preset_buttons[preset] as Button).set_pressed_no_signal(preset == active)
	if _preset_caption != null:
		_preset_caption.text = CUSTOM_LABEL if active == LAGameSettings.SimPreset.CUSTOM else "Preset: %s" % _preset_name(active)


func _add_preset(row: HBoxContainer, preset: int, text: String, tooltip: String) -> void:
	_preset_buttons[preset] = LASettingsWidgets.add_preset_button(row, text, _preset_group, tooltip, Callable(self, "_on_preset").bind(preset))


func _preset_name(preset: int) -> String:
	match preset:
		LAGameSettings.SimPreset.LOW: return "Low"
		LAGameSettings.SimPreset.MEDIUM: return "Medium"
		LAGameSettings.SimPreset.HIGH: return "High"
		LAGameSettings.SimPreset.ULTRA: return "Ultra"
		_: return "Custom"


## Verification aid: move the population slider off its preset value so the section flips to Custom, driving
## the same value_changed handler a player drag would. Used by the --demo-custom shot.
func demo_nudge() -> void:
	if _pop_slider != null:
		_pop_slider.value = float(clampi(_settings.actor_budget + 80, 20, 480))


func _fmt_int(v: float) -> String:
	return "%d" % int(round(v))


func _fmt_every_frames(v: float) -> String:
	var n: int = int(round(v))
	return "every frame" if n <= 1 else "every %d frames" % n


func _fmt_seconds(v: float) -> String:
	return "%.0f s" % v
