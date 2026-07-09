class_name LAHelpMenu
extends Control

## LAHelpMenu — a scrollable help / controls screen reached from the main menu. Static reference text
## (modes, camera, interaction, pause) with a Back button that returns to the main menu. Built in code
## to match the shared menu styling (LAMenuStyle); keyboard-navigable. (Explicit types only — no ':='.)

const MAIN_MENU_SCENE: String = "res://addons/local_agents/scenes/menu/MainMenu.tscn"

const HELP_SECTIONS: Array = [
	{
		"title": "Modes",
		"body": "New campaign plays with progression gating on. Sandbox is free play with gating off. Both drop you into the same living world.",
	},
	{
		"title": "Camera",
		"body": "Switch between the close planet view and the pulled-back solar-system overview. Orbit keeps the camera fixed in world, Geosync rides the planet's spin, and Fly is a free-flight drone. Auto-spin turns the planet in front of you.",
	},
	{
		"title": "Interaction",
		"body": "Click a creature to select and inspect it. Use the spawn palette to place life and matter, and the brush to paint a radius of it.",
	},
	{
		"title": "Pause and speed",
		"body": "Press Esc in the sim to pause and open the pause menu. From there you can change the time speed to fast-forward slow, emergent processes like geology and weather.",
	},
	{
		"title": "Settings",
		"body": "Tune difficulty, quality/performance, and audio from the main menu. Lower the quality preset if your GPU struggles.",
	},
]


func _ready() -> void:
	_build_ui()
	add_child(LAMenuShooter.new())


func _build_ui() -> void:
	var bg: ColorRect = ColorRect.new()
	bg.color = LAMenuStyle.OVERLAY_BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	var center: CenterContainer = CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var panel: PanelContainer = PanelContainer.new()
	panel.add_theme_stylebox_override("panel", LAMenuStyle.panel_style())
	center.add_child(panel)

	var vbox: VBoxContainer = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	vbox.custom_minimum_size = Vector2(460.0, 0.0)
	panel.add_child(vbox)

	vbox.add_child(LAMenuStyle.make_title("Help"))

	var scroll: ScrollContainer = ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.custom_minimum_size = Vector2(460.0, 440.0)
	vbox.add_child(scroll)

	var text_col: VBoxContainer = VBoxContainer.new()
	text_col.add_theme_constant_override("separation", 12)
	text_col.custom_minimum_size = Vector2(444.0, 0.0)
	text_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(text_col)

	for section in HELP_SECTIONS:
		var heading: Label = Label.new()
		heading.text = String(section["title"])
		heading.add_theme_color_override("font_color", LAMenuStyle.ACCENT)
		heading.add_theme_font_size_override("font_size", 16)
		text_col.add_child(heading)

		var body: Label = Label.new()
		body.text = String(section["body"])
		body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		body.add_theme_color_override("font_color", LAMenuStyle.TEXT)
		body.add_theme_font_size_override("font_size", 13)
		body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		text_col.add_child(body)

	var back_button: Button = LAMenuStyle.make_button("Back")
	back_button.pressed.connect(_on_back)
	vbox.add_child(back_button)
	back_button.grab_focus()


func _on_back() -> void:
	var err: int = get_tree().change_scene_to_file(MAIN_MENU_SCENE)
	if err != OK:
		push_error("HelpMenu: failed to return to main menu (err=%d)" % err)
