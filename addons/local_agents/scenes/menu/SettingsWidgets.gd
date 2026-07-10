class_name LASettingsWidgets
extends RefCounted

## LASettingsWidgets — the shared control builders for the settings screen, so the difficulty, graphics,
## simulation and audio sections all draw the SAME labelled-slider / dropdown / preset-row widgets instead
## of each re-implementing them. Every builder attaches a tooltip (what the setting affects + whether the
## cost is GPU or CPU) that Godot shows on hover — the reused, metadata-free tooltip mechanism the rest of
## the menus use. Numeric sliders show a live value readout formatted by a caller-supplied Callable, so a
## population slider reads "200", a resolution slider "72" and a distance slider "800 m".
##
## Pure static builders returning the created nodes (no state); the section objects hold the returned refs
## and drive them. (Explicit types only — no ':=' inferred typing.)

const SECTION_ACCENT: Color = Color(0.55, 0.72, 1.0)
const TEXT: Color = Color(0.90, 0.92, 0.95)
const TEXT_DIM: Color = Color(0.62, 0.66, 0.72)


## A section header — a faint rule then an accented caption.
static func add_header(col: VBoxContainer, text: String) -> void:
	var rule: ColorRect = ColorRect.new()
	rule.color = Color(SECTION_ACCENT.r, SECTION_ACCENT.g, SECTION_ACCENT.b, 0.35)
	rule.custom_minimum_size = Vector2(0.0, 1.0)
	rule.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_child(rule)
	var label: Label = Label.new()
	label.text = text
	label.add_theme_color_override("font_color", SECTION_ACCENT)
	label.add_theme_font_size_override("font_size", 16)
	col.add_child(label)


## An empty HBox row (used for preset button rows and the action bar).
static func add_row(col: VBoxContainer) -> HBoxContainer:
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	col.add_child(row)
	return row


## A toggle preset button inside a ButtonGroup row. `cb` fires on press.
static func add_preset_button(row: HBoxContainer, text: String, group: ButtonGroup, tooltip: String, cb: Callable) -> Button:
	var button: Button = Button.new()
	button.text = text
	button.toggle_mode = true
	button.button_group = group
	button.focus_mode = Control.FOCUS_ALL
	button.tooltip_text = tooltip
	button.custom_minimum_size = Vector2(0.0, 36.0)
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.pressed.connect(cb)
	row.add_child(button)
	return button


## A labelled numeric slider row: [caption ....... value] then the slider. The live value Label is
## formatted by `fmt` (a Callable(float) -> String). `changed` fires with the new float on drag. Returns
## {"slider": HSlider, "value": Label} so the caller can refresh it later. `tooltip` shows on hover.
static func add_slider(col: VBoxContainer, caption_text: String, tooltip: String, min_v: float, max_v: float, step: float, initial: float, fmt: Callable, changed: Callable) -> Dictionary:
	var header: HBoxContainer = HBoxContainer.new()
	header.tooltip_text = tooltip
	header.mouse_filter = Control.MOUSE_FILTER_PASS
	col.add_child(header)
	var caption: Label = Label.new()
	caption.text = caption_text
	caption.tooltip_text = tooltip
	caption.mouse_filter = Control.MOUSE_FILTER_PASS
	caption.add_theme_color_override("font_color", TEXT_DIM)
	caption.add_theme_font_size_override("font_size", 13)
	caption.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(caption)
	var value: Label = Label.new()
	value.text = String(fmt.call(initial))
	value.add_theme_color_override("font_color", TEXT)
	value.add_theme_font_size_override("font_size", 13)
	value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	value.custom_minimum_size = Vector2(96.0, 0.0)
	header.add_child(value)

	var slider: HSlider = HSlider.new()
	slider.min_value = min_v
	slider.max_value = max_v
	slider.step = step
	slider.value = initial
	slider.focus_mode = Control.FOCUS_ALL
	slider.tooltip_text = tooltip
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.value_changed.connect(changed)
	col.add_child(slider)
	return {"slider": slider, "value": value}


## A labelled dropdown row for a categorical setting: [caption] [OptionButton]. `options` are the item
## labels in enum order; `selected` is the initial index. `changed` fires with the picked index. Returns
## the OptionButton so the caller can refresh its selection.
static func add_option(col: VBoxContainer, caption_text: String, tooltip: String, options: Array, selected: int, changed: Callable) -> OptionButton:
	var row: HBoxContainer = HBoxContainer.new()
	row.tooltip_text = tooltip
	col.add_child(row)
	var caption: Label = Label.new()
	caption.text = caption_text
	caption.tooltip_text = tooltip
	caption.add_theme_color_override("font_color", TEXT_DIM)
	caption.add_theme_font_size_override("font_size", 13)
	caption.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(caption)
	var option: OptionButton = OptionButton.new()
	option.tooltip_text = tooltip
	option.focus_mode = Control.FOCUS_ALL
	option.custom_minimum_size = Vector2(150.0, 32.0)
	for i in options.size():
		option.add_item(String(options[i]), i)
	option.selected = clampi(selected, 0, options.size() - 1)
	option.item_selected.connect(changed)
	col.add_child(option)
	return option
