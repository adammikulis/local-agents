class_name LAControlsReference
extends RefCounted

## LAControlsReference — the controls screen, built entirely from LAHotkeyRegistry.hotkey_map() (the ONE
## source of truth for the sim's key bindings) grouped by category, so it can never drift from the keys the
## input router actually reads. Pure static builder returning a scrollable Control; reused by BOTH the
## main-menu Help screen and the in-sim pause menu's "Controls & help" overlay, so there is exactly one
## controls list in the codebase. No state, no second hardcoded table. (Explicit types only — no ':=' .)

const ACCENT: Color = Color(0.55, 0.72, 1.0)
const TEXT: Color = Color(0.90, 0.92, 0.95)
const TEXT_DIM: Color = Color(0.62, 0.66, 0.72)
const KEY_BG: Color = Color(0.13, 0.16, 0.22, 1.0)
const KEY_BORDER: Color = Color(0.30, 0.36, 0.46, 1.0)


## Build the scrollable, category-grouped controls list. `width`/`height` size the scroll viewport; the
## content wraps within it. Every row is generated from the live registry catalog.
static func build_scroll(width: float, height: float) -> Control:
	var scroll: ScrollContainer = ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.custom_minimum_size = Vector2(width, height)

	var col: VBoxContainer = VBoxContainer.new()
	col.add_theme_constant_override("separation", 14)
	col.custom_minimum_size = Vector2(width - 20.0, 0.0)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(col)

	# Group the flat catalog by category, preserving each category's first-seen order.
	var order: Array = []
	var grouped: Dictionary = {}
	for row in LAHotkeyRegistry.hotkey_map():
		var cat: String = String(row.get("category", "Other"))
		if not grouped.has(cat):
			grouped[cat] = []
			order.append(cat)
		(grouped[cat] as Array).append(row)

	for cat in order:
		col.add_child(_category_header(String(cat)))
		var grid: GridContainer = GridContainer.new()
		grid.columns = 2
		grid.add_theme_constant_override("h_separation", 16)
		grid.add_theme_constant_override("v_separation", 7)
		grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		col.add_child(grid)
		for row in grouped[cat]:
			grid.add_child(_key_chip(String(row.get("key", ""))))
			grid.add_child(_action_label(String(row.get("label", ""))))
	return scroll


static func _category_header(text: String) -> Control:
	var box: VBoxContainer = box_column()
	var label: Label = Label.new()
	label.text = text
	label.add_theme_color_override("font_color", ACCENT)
	label.add_theme_font_size_override("font_size", 16)
	box.add_child(label)
	var rule: ColorRect = ColorRect.new()
	rule.color = KEY_BORDER
	rule.custom_minimum_size = Vector2(0.0, 1.0)
	rule.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(rule)
	return box


static func box_column() -> VBoxContainer:
	var box: VBoxContainer = VBoxContainer.new()
	box.add_theme_constant_override("separation", 3)
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return box


# The key drawn as a small "keycap" chip so bindings scan at a glance.
static func _key_chip(key: String) -> Control:
	var panel: PanelContainer = PanelContainer.new()
	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = KEY_BG
	style.set_corner_radius_all(5)
	style.set_border_width_all(1)
	style.border_color = KEY_BORDER
	style.content_margin_left = 9.0
	style.content_margin_right = 9.0
	style.content_margin_top = 3.0
	style.content_margin_bottom = 3.0
	panel.add_theme_stylebox_override("panel", style)
	panel.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	panel.custom_minimum_size = Vector2(96.0, 0.0)
	var label: Label = Label.new()
	label.text = key
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_color_override("font_color", TEXT)
	label.add_theme_font_size_override("font_size", 13)
	panel.add_child(label)
	return panel


static func _action_label(text: String) -> Label:
	var label: Label = Label.new()
	label.text = text
	label.add_theme_color_override("font_color", TEXT)
	label.add_theme_font_size_override("font_size", 13)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return label
