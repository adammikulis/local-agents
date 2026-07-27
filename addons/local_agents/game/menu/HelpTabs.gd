class_name LAHelpTabs
extends RefCounted

## LAHelpTabs — the shared help hub: a segmented [Overview | Controls | Codex] switcher over three panels,
## returned as one Control so BOTH the main-menu Help screen and the in-sim pause-menu overlay show the exact
## same reference, from one place. Overview is a short orientation blurb, Controls is the auto-generated key
## reference (LAControlsReference, straight from LAHotkeyRegistry), and Codex is the browsable manual
## (LAHelpCodex). Pure static builder. (Explicit types only — no ':=' inferred typing.)

const ACCENT: Color = Color(0.55, 0.72, 1.0)
const TEXT: Color = Color(0.90, 0.92, 0.95)

# Short orientation cards for a returning player — the "where am I" blurb, not the full manual (that's Codex).
const OVERVIEW_SECTIONS: Array = [
	{
		"title": "Welcome back",
		"body": "This is a living world simulated on your own machine. You are its caretaker: seed life and matter, stir up disasters, and watch an ecosystem run itself. Nothing here is scripted — behaviour emerges from simple physical rules.",
	},
	{
		"title": "Getting your bearings",
		"body": "Drag to rotate the planet and scroll to zoom. The bottom palette is your spawn toolkit, the top bar switches camera modes, and Esc pauses and opens the menu. See Controls for every key, and Codex for a guide to each mechanic.",
	},
	{
		"title": "Campaign vs sandbox",
		"body": "A campaign gates spawns and camera powers behind objectives you clear; sandbox unlocks everything for free play. Both drop you into the same simulated world.",
	},
]


## Build the segmented help hub sized to (width, height). `start_tab` is "overview" / "controls" / "codex".
static func build(width: float, height: float, start_tab: String = "overview") -> Control:
	var col: VBoxContainer = VBoxContainer.new()
	col.add_theme_constant_override("separation", 12)
	col.custom_minimum_size = Vector2(width, 0.0)

	# --- Segment switcher row ---
	var seg_row: HBoxContainer = HBoxContainer.new()
	seg_row.alignment = BoxContainer.ALIGNMENT_CENTER
	seg_row.add_theme_constant_override("separation", 6)
	col.add_child(seg_row)

	# --- Content area holding all three panels; only one visible at a time ---
	var content: Control = Control.new()
	content.custom_minimum_size = Vector2(width, height)
	col.add_child(content)

	var overview: Control = _overview_panel(width, height)
	var controls: Control = LAControlsReference.build_scroll(width, height)
	var codex: LAHelpCodex = LAHelpCodex.new()
	var panels: Array = [overview, controls, codex]
	for p in panels:
		(p as Control).set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		content.add_child(p)

	var group: ButtonGroup = ButtonGroup.new()
	var labels: PackedStringArray = ["Overview", "Controls", "Codex"]
	var buttons: Array[Button] = []
	for i in labels.size():
		var b: Button = _segment_button(labels[i], group)
		var idx: int = i
		b.pressed.connect(func() -> void: _select(panels, idx))
		seg_row.add_child(b)
		buttons.append(b)

	var start_index: int = _tab_index(start_tab)
	buttons[start_index].set_pressed_no_signal(true)
	_select(panels, start_index)
	return col


static func _select(panels: Array, index: int) -> void:
	for i in panels.size():
		(panels[i] as Control).visible = (i == index)


static func _tab_index(tab: String) -> int:
	match tab.to_lower():
		"controls":
			return 1
		"codex":
			return 2
		_:
			return 0


static func _segment_button(text: String, group: ButtonGroup) -> Button:
	var b: Button = Button.new()
	b.text = text
	b.toggle_mode = true
	b.button_group = group
	b.focus_mode = Control.FOCUS_ALL
	b.custom_minimum_size = Vector2(120.0, 34.0)
	return b


static func _overview_panel(width: float, height: float) -> Control:
	var scroll: ScrollContainer = ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.custom_minimum_size = Vector2(width, height)

	var col: VBoxContainer = VBoxContainer.new()
	col.add_theme_constant_override("separation", 12)
	col.custom_minimum_size = Vector2(width - 20.0, 0.0)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(col)

	for section in OVERVIEW_SECTIONS:
		var heading: Label = Label.new()
		heading.text = String(section["title"])
		heading.add_theme_color_override("font_color", ACCENT)
		heading.add_theme_font_size_override("font_size", 16)
		col.add_child(heading)

		var body: Label = Label.new()
		body.text = String(section["body"])
		body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		body.add_theme_color_override("font_color", TEXT)
		body.add_theme_font_size_override("font_size", 13)
		body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		col.add_child(body)
	return scroll
