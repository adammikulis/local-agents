class_name LAMenuStyle
extends RefCounted


const OVERLAY_BG: Color = Color(0.02, 0.03, 0.06, 1.0)
const ACCENT: Color = Color(0.55, 0.72, 1.0)
const TEXT: Color = Color(0.90, 0.92, 0.95)
const TEXT_DIM: Color = Color(0.62, 0.66, 0.72)

const PANEL_STYLE: StyleBoxFlat = preload("res://addons/local_agents/game/menu/MenuPanel.tres")
const ModelManagerPanelScene: PackedScene = preload("res://addons/local_agents/ui/ModelManagerPanel.tscn")


## The bordered deep-blue panel used behind every menu's content (matches the pause menu).
static func panel_style() -> StyleBoxFlat:
	return PANEL_STYLE


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


## Open the model manager as a full-screen overlay over `host`; Close frees it.
static func open_model_manager(host: Control) -> void:
	var overlay: Control = Control.new()
	overlay.name = "ModelManagerOverlay"
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	host.add_child(overlay)

	var panel: Control = ModelManagerPanelScene.instantiate()
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.add_child(panel)
	panel.open()

	var close_button: Button = make_button("Close")
	close_button.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	close_button.offset_left = -140.0
	close_button.offset_top = 12.0
	close_button.offset_right = -16.0
	close_button.custom_minimum_size = Vector2(120.0, 40.0)
	close_button.pressed.connect(overlay.queue_free)
	overlay.add_child(close_button)
	close_button.grab_focus()
