class_name LAPauseSettingsPanel
extends VBoxContainer

## PauseSettingsPanel — the in-game settings block hosted inside the Esc pause menu. Three DESCRIPTIVE tier
## selectors (Graphics · Simulation/CPU · Animal cognition), each a row of named-tier buttons with a plain
## sentence under it explaining WHAT the tier does — no magic numbers or raw units shown to the player. Owns
## no state of its own: it reads the live LAGameSettings off the GameMode autoload, mutates it on a pick, and
## routes the change through GameMode.apply() (the single application entry point) so the settings applier
## re-publishes the live knobs — field/creature cadence + cognition cadence + effects density take effect the
## next frame without a rebuild. The change is also persisted to disk. Split into its own module so the pause
## menu stays a thin host (file-size + one-owner discipline). (Explicit types only — no ':=' inferred typing.)

const HEADING: Color = Color(0.72, 0.82, 1.0)
const DESC: Color = Color(0.68, 0.72, 0.8)
const ACCENT: Color = Color(0.55, 0.72, 1.0)

# --- Tier tables ------------------------------------------------------------------------------------------
# Each tier is [button label, one-sentence description of its EFFECT]. The index maps to a settings value in
# _apply_* below. Ordered cheapest → richest so the row reads left (fast) to right (heavy).

const GRAPHICS_TIERS: Array = [
	["Low", "Fewest effects and a coarse world. Best frame rate on a weak GPU."],
	["Medium", "A balanced look — modest effects, no sun shadows."],
	["High", "Richer effects and soft shadows. Needs a capable GPU."],
	["Ultra", "Everything on at the finest world detail. For strong GPUs."],
]
# Maps a graphics tier index to the GraphicsPreset enum (skips POTATO/CUSTOM — the four the player picks from).
const GRAPHICS_PRESET_BY_TIER: Array = [
	LAGameSettings.GraphicsPreset.LOW,
	LAGameSettings.GraphicsPreset.MEDIUM,
	LAGameSettings.GraphicsPreset.HIGH,
	LAGameSettings.GraphicsPreset.ULTRA,
]

const SIM_TIERS: Array = [
	["Light", "Fewer animals and the world's physics updates less often. Frees up the processor for a smoother frame rate."],
	["Balanced", "A full world with physics every frame. The default."],
	["Busy", "More animals and quicker reactions. Asks more of the processor."],
	["Max", "As many animals and as fine a simulation as the processor can drive."],
]
const SIM_PRESET_BY_TIER: Array = [
	LAGameSettings.SimPreset.LOW,
	LAGameSettings.SimPreset.MEDIUM,
	LAGameSettings.SimPreset.HIGH,
	LAGameSettings.SimPreset.ULTRA,
]

const COGNITION_TIERS: Array = [
	["Instinct", "Animals act on hard-wired instinct alone. The local AI model stays idle — lightest on the processor."],
	["Occasional", "Animals consult the local AI model now and then, for genuinely tricky choices."],
	["Frequent", "Animals think with the local AI model often, for richer, more surprising behaviour."],
	["Constant", "Animals lean on the local AI model as much as possible. The most lifelike, and the heaviest."],
]
# Cognition tier → seconds between local-model cognition calls (llm_cadence). Larger = the model runs less
# often. "Instinct" parks it high enough that the model effectively never drives a decision.
const COGNITION_CADENCE_BY_TIER: Array = [120.0, 24.0, 12.0, 5.0]

var _graphics_buttons: Array[Button] = []
var _sim_buttons: Array[Button] = []
var _cognition_buttons: Array[Button] = []
var _graphics_desc: Label = null
var _sim_desc: Label = null
var _cognition_desc: Label = null


func _ready() -> void:
	add_theme_constant_override("separation", 10)
	custom_minimum_size = Vector2(320.0, 0.0)
	var s: LAGameSettings = _settings()
	_graphics_buttons = _build_row("Graphics", GRAPHICS_TIERS, _graphics_tier_of(s), _on_graphics, false)
	_graphics_desc = get_child(get_child_count() - 1) as Label
	_sim_buttons = _build_row("Simulation (processor)", SIM_TIERS, _sim_tier_of(s), _on_sim, false)
	_sim_desc = get_child(get_child_count() - 1) as Label
	_cognition_buttons = _build_row("Animal cognition", COGNITION_TIERS, _cognition_tier_of(s), _on_cognition, true)
	_cognition_desc = get_child(get_child_count() - 1) as Label
	_refresh_descriptions()


# Build one titled tier-selector row: a heading, a button row (one toggle per tier), and a description label
# under it. Returns the button array; the description label is the last child added (grabbed by the caller).
func _build_row(title: String, tiers: Array, active: int, cb: Callable, spacer: bool) -> Array[Button]:
	if spacer:
		var sep: HSeparator = HSeparator.new()
		add_child(sep)
	var head: Label = Label.new()
	head.text = title
	head.add_theme_color_override("font_color", HEADING)
	head.add_theme_font_size_override("font_size", 15)
	add_child(head)

	var row: HBoxContainer = HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 6)
	add_child(row)
	var buttons: Array[Button] = []
	for i in range(tiers.size()):
		var b: Button = Button.new()
		b.text = String(tiers[i][0])
		b.toggle_mode = true
		b.button_pressed = (i == active)
		b.custom_minimum_size = Vector2(72.0, 32.0)
		b.pressed.connect(cb.bind(i))
		row.add_child(b)
		buttons.append(b)

	var desc: Label = Label.new()
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.custom_minimum_size = Vector2(320.0, 0.0)
	desc.add_theme_color_override("font_color", DESC)
	desc.add_theme_font_size_override("font_size", 12)
	add_child(desc)
	return buttons


# --- Selection handlers -----------------------------------------------------------------------------------

func _on_graphics(tier: int) -> void:
	var s: LAGameSettings = _settings()
	s.apply_graphics_preset(GRAPHICS_PRESET_BY_TIER[tier])
	_select(_graphics_buttons, tier)
	_apply_live(s)

func _on_sim(tier: int) -> void:
	var s: LAGameSettings = _settings()
	s.apply_sim_preset(SIM_PRESET_BY_TIER[tier])
	_select(_sim_buttons, tier)
	_apply_live(s)

func _on_cognition(tier: int) -> void:
	var s: LAGameSettings = _settings()
	# Cognition is its own axis: keep the rest of the sim preset, change only how often the model may think.
	s.llm_cadence = float(COGNITION_CADENCE_BY_TIER[tier])
	_select(_cognition_buttons, tier)
	_apply_live(s)


# --- Apply + persist --------------------------------------------------------------------------------------

## Route the mutated settings through the single application entry point (GameMode.apply → settings_applied →
## the settings applier re-publishes the live knobs), then persist to disk. Falls back to a direct save when
## GameMode is absent (e.g. a demo scene) so the pick is at least remembered.
func _apply_live(s: LAGameSettings) -> void:
	var gm: Node = get_node_or_null("/root/GameMode")
	if gm != null and gm.has_method("apply"):
		gm.apply(s)
	s.save()
	_refresh_descriptions()


func _select(buttons: Array[Button], active: int) -> void:
	for i in range(buttons.size()):
		buttons[i].button_pressed = (i == active)


func _refresh_descriptions() -> void:
	var s: LAGameSettings = _settings()
	if _graphics_desc != null:
		_graphics_desc.text = String(GRAPHICS_TIERS[_graphics_tier_of(s)][1])
	if _sim_desc != null:
		_sim_desc.text = String(SIM_TIERS[_sim_tier_of(s)][1])
	if _cognition_desc != null:
		_cognition_desc.text = String(COGNITION_TIERS[_cognition_tier_of(s)][1])


# --- Current-tier resolution (settings value → tier index) ------------------------------------------------

func _settings() -> LAGameSettings:
	var gm: Node = get_node_or_null("/root/GameMode")
	if gm != null and "settings" in gm and gm.settings != null:
		return gm.settings
	return LAGameSettings.load_or_default()

func _graphics_tier_of(s: LAGameSettings) -> int:
	var idx: int = GRAPHICS_PRESET_BY_TIER.find(s.graphics_preset)
	return idx if idx >= 0 else 1     # a CUSTOM/POTATO config reads as the nearest shown tier (Medium)

func _sim_tier_of(s: LAGameSettings) -> int:
	var idx: int = SIM_PRESET_BY_TIER.find(s.sim_preset)
	return idx if idx >= 0 else 1

func _cognition_tier_of(s: LAGameSettings) -> int:
	# Pick the tier whose cadence is closest to the stored llm_cadence (it is an independent axis, not a preset).
	var best: int = 0
	var best_d: float = 1.0e9
	for i in range(COGNITION_CADENCE_BY_TIER.size()):
		var d: float = absf(float(COGNITION_CADENCE_BY_TIER[i]) - s.llm_cadence)
		if d < best_d:
			best_d = d
			best = i
	return best
