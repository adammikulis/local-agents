class_name LAMenuStyle
extends RefCounted

## LAMenuStyle — shared look for the front-end menus (main / settings / help), so all three read as one
## system and match the in-sim pause menu / view-controls palette (the same deep-blue panel + light-blue
## accent). Pure static builders; no state. Keeps each menu script free of duplicated stylebox setup.
## (Explicit types only — no ':=' inferred typing.)

const OVERLAY_BG: Color = Color(0.02, 0.03, 0.06, 1.0)
const PANEL_BG: Color = Color(0.06, 0.08, 0.12, 0.96)
const ACCENT: Color = Color(0.55, 0.72, 1.0)
const TEXT: Color = Color(0.90, 0.92, 0.95)
const TEXT_DIM: Color = Color(0.62, 0.66, 0.72)


## The bordered deep-blue panel used behind every menu's content (matches the pause menu).
static func panel_style() -> StyleBoxFlat:
	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = PANEL_BG
	style.set_corner_radius_all(10)
	style.set_border_width_all(2)
	style.border_color = ACCENT
	style.set_content_margin_all(28.0)
	return style


## A large accent title label, centre-aligned.
static func make_title(text: String) -> Label:
	var title: Label = Label.new()
	title.text = text
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 34)
	title.add_theme_color_override("font_color", ACCENT)
	return title


## A dimmer, smaller subtitle / caption label.
static func make_caption(text: String) -> Label:
	var caption: Label = Label.new()
	caption.text = text
	caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	caption.add_theme_color_override("font_color", TEXT_DIM)
	caption.add_theme_font_size_override("font_size", 13)
	return caption


## A full-width menu button (keyboard-focusable) at the standard menu height.
static func make_button(text: String) -> Button:
	var button: Button = Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(300.0, 46.0)
	button.focus_mode = Control.FOCUS_ALL
	return button
