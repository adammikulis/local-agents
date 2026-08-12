class_name LADebugPanel
extends CanvasLayer


signal view_toggled(view: String, on: bool)          # "temp"|"wind"|"scent"|a field-channel key
signal highlight_toggled(group: String, on: bool)    # a "species_*" or "nest" group
signal behavior_toggled(behavior: String, on: bool)  # a creature behavior-state category
signal paths_toggled(on: bool)
signal perf_toggled(key: String, on: bool)           # "shadows" | "ssao"
signal family_tree_toggled(on: bool)
signal screenshot_requested()
signal select_llm_requested(kind: String)
signal perf_overlay_toggled(on: bool)
signal render_debug_toggled(mode: String, on: bool)  # "wireframe" | "overdraw"

# [display label, view_toggled key] — the DebugOverlay samples that channel.
const FIELD_VIEWS: Array = [
	["Biomass", "biomass"], ["Water phase", "water_phase"], ["Snow / ice", "snow"],
	["Lava", "lava"], ["Rock fill", "rock_fill"], ["CO₂", "co2"], ["O₂", "o2"],
	["Charge", "charge"], ["Fertility", "fertility"],
]

# [display label, scene group to light up]
const HIGHLIGHTS: Array = [
	["Rabbits", "species_rabbit"], ["Foxes", "species_fox"], ["Birds", "species_bird"],
	["Vultures", "species_vulture"], ["Villagers", "species_villager"], ["Fish", "species_fish"],
	["Plants", "species_plant"], ["Nests", "nest"],
]

# [display label, behavior category]. Idle/Wander has no tint, so it is omitted.
const BEHAVIORS: Array = [
	["Foraging", "foraging"], ["Hunting", "hunting"], ["Fleeing", "fleeing"],
	["Drinking", "drinking"], ["Sleeping", "sleeping"], ["Nesting / Mating", "nesting"],
]

# [display label, LALLMControl.HL_* tint category]. Routed through behavior_toggled.
const LLM_HIGHLIGHTS: Array = [
	["Thinking (local model)", "llm_thinking"], ["Queued", "llm_queued"],
]

@onready var _header: Button = $Panel/Col/Header
@onready var _body: VBoxContainer = $Panel/Col/Scroll/Body

var _collapsed: bool = false


func _ready() -> void:
	_header.pressed.connect(_toggle_collapsed)

	_add_section("VIEWS")
	_add_check("Temperature", func(on: bool) -> void: view_toggled.emit("temp", on))
	_add_check("Wind", func(on: bool) -> void: view_toggled.emit("wind", on))
	_add_check("Scent", func(on: bool) -> void: view_toggled.emit("scent", on))
	for frow in FIELD_VIEWS:
		var vkey: String = frow[1]
		_add_check(frow[0], func(on: bool) -> void: view_toggled.emit(vkey, on))

	_add_section("HIGHLIGHT · SPECIES")
	for row in HIGHLIGHTS:
		var group: String = row[1]
		_add_check(row[0], func(on: bool) -> void: highlight_toggled.emit(group, on))

	_add_section("HIGHLIGHT · BEHAVIOR")
	for brow in BEHAVIORS:
		var bkey: String = brow[1]
		_add_check(brow[0], func(on: bool) -> void: behavior_toggled.emit(bkey, on))

	_add_section("HIGHLIGHT · LOCAL MODEL")
	for lrow in LLM_HIGHLIGHTS:
		var lkey: String = lrow[1]
		_add_check(lrow[0], func(on: bool) -> void: behavior_toggled.emit(lkey, on))
	var pick_llm: Button = Button.new()
	pick_llm.text = "◎  Select thinking / queued"
	pick_llm.add_theme_font_size_override("font_size", 12)
	pick_llm.pressed.connect(func() -> void: select_llm_requested.emit("any"))
	_body.add_child(pick_llm)

	_add_section("INSPECT")
	_add_check("Family tree", func(on: bool) -> void: family_tree_toggled.emit(on))

	_add_section("OVERLAY")
	_add_check("Intended paths", func(on: bool) -> void: paths_toggled.emit(on))

	_add_section("PERF")
	# Start OFF with no emit — the applied quality preset owns the real render state.
	var shadows: CheckButton = _add_check("Sun shadows", func(on: bool) -> void: perf_toggled.emit("shadows", on))
	shadows.set_pressed_no_signal(false)
	var ssao: CheckButton = _add_check("SSAO", func(on: bool) -> void: perf_toggled.emit("ssao", on))
	ssao.set_pressed_no_signal(false)

	_add_section("STATS")
	_add_check("Detailed perf readout", func(on: bool) -> void: perf_overlay_toggled.emit(on))

	_add_section("RENDER DEBUG")
	_add_check("Wireframe", func(on: bool) -> void: render_debug_toggled.emit("wireframe", on))
	_add_check("Overdraw", func(on: bool) -> void: render_debug_toggled.emit("overdraw", on))

	_add_section("CAPTURE")
	var shot: Button = Button.new()
	shot.text = "📷  Save screenshot"
	shot.add_theme_font_size_override("font_size", 12)
	shot.pressed.connect(func() -> void: screenshot_requested.emit())
	_body.add_child(shot)


func _toggle_collapsed() -> void:
	_collapsed = not _collapsed
	_body.visible = not _collapsed


func _add_section(title: String) -> void:
	var lbl: Label = Label.new()
	lbl.text = title
	lbl.add_theme_font_size_override("font_size", 10)
	lbl.add_theme_color_override("font_color", Color(0.6, 0.68, 0.8))
	var m: MarginContainer = MarginContainer.new()
	m.add_theme_constant_override("margin_top", 4)
	m.add_child(lbl)
	_body.add_child(m)


func _add_check(label: String, cb: Callable) -> CheckButton:
	var c: CheckButton = CheckButton.new()
	c.text = label
	c.add_theme_font_size_override("font_size", 12)
	c.toggled.connect(cb)
	_body.add_child(c)
	return c
