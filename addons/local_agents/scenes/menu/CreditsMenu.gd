class_name LACreditsMenu
extends Control

## LACreditsMenu — a scrollable credits screen reached from the main menu. It leads with the game's
## creator, then lists the third-party work Local Agents is built on, grouped by category (engine & tools,
## art, voice, AI models) with each item's license and source URL. A Back button returns to the main menu.
## Built in code to match the shared menu styling (LAMenuStyle); keyboard-navigable. The content is
## SELF-CONTAINED — hardcoded below, NOT read/parsed from CREDITS.md / AUTHORS at runtime — so the in-game
## screen and the repo docs are maintained independently (some overlap is intended). (Explicit types only.)

const MAIN_MENU_SCENE: String = "res://addons/local_agents/scenes/menu/MainMenu.tscn"

const CREATED_BY: String = "Adam Mikulis"

## Grouped credits. Each group has a heading and a list of entries; each entry is name · license · url.
const CREDIT_GROUPS: Array = [
	{
		"title": "Engine & tools",
		"entries": [
			{"name": "Godot Engine", "license": "MIT", "url": "https://godotengine.org"},
			{"name": "godot-cpp (GDExtension bindings)", "license": "MIT", "url": "https://github.com/godotengine/godot-cpp"},
			{"name": "godot_voxel — Zylann / Marc Gilleron", "license": "MIT", "url": "https://github.com/Zylann/godot_voxel"},
			{"name": "llama.cpp — the ggml authors", "license": "MIT", "url": "https://github.com/ggml-org/llama.cpp"},
			{"name": "whisper.cpp — the ggml authors", "license": "MIT", "url": "https://github.com/ggml-org/whisper.cpp"},
		],
	},
	{
		"title": "Art",
		"entries": [
			{"name": "Kenney — Cube Pets & Nature Kit", "license": "CC0", "url": "https://kenney.nl"},
			{"name": "Quaternius — creatures & character", "license": "CC0", "url": "https://quaternius.com"},
		],
	},
	{
		"title": "Voice",
		"entries": [
			{"name": "Piper TTS (rhasspy/piper)", "license": "MIT", "url": "https://github.com/rhasspy/piper"},
			{"name": "rhasspy/piper-voices", "license": "MIT / CC0", "url": "https://huggingface.co/rhasspy/piper-voices"},
		],
	},
	{
		"title": "AI models (downloaded at runtime)",
		"entries": [
			{"name": "Qwen3 (0.6B–14B)", "license": "Apache-2.0", "url": "https://huggingface.co/Qwen"},
			{"name": "Qwen2.5-3B-Instruct", "license": "Qwen Research License", "url": "https://huggingface.co/Qwen/Qwen2.5-3B-Instruct"},
			{"name": "FunctionGemma-270M (Google, Gemma 3)", "license": "Gemma Terms of Use", "url": "https://ai.google.dev/gemma/terms"},
		],
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
	vbox.custom_minimum_size = Vector2(480.0, 0.0)
	panel.add_child(vbox)

	vbox.add_child(LAMenuStyle.make_title("Credits"))

	# Created-by line up top — the game's creator, above the third-party attributions.
	var created_heading: Label = Label.new()
	created_heading.text = "Created by"
	created_heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	created_heading.add_theme_color_override("font_color", LAMenuStyle.TEXT_DIM)
	created_heading.add_theme_font_size_override("font_size", 13)
	vbox.add_child(created_heading)

	var created_name: Label = Label.new()
	created_name.text = CREATED_BY
	created_name.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	created_name.add_theme_color_override("font_color", LAMenuStyle.TEXT)
	created_name.add_theme_font_size_override("font_size", 22)
	vbox.add_child(created_name)

	var scroll: ScrollContainer = ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.custom_minimum_size = Vector2(480.0, 420.0)
	vbox.add_child(scroll)

	var col: VBoxContainer = VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)
	col.custom_minimum_size = Vector2(464.0, 0.0)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(col)

	for group in CREDIT_GROUPS:
		var heading: Label = Label.new()
		heading.text = String(group["title"])
		heading.add_theme_color_override("font_color", LAMenuStyle.ACCENT)
		heading.add_theme_font_size_override("font_size", 16)
		col.add_child(heading)

		for entry in group["entries"]:
			col.add_child(_make_entry(entry))

		var gap: Control = Control.new()
		gap.custom_minimum_size = Vector2(0.0, 6.0)
		col.add_child(gap)

	var back_button: Button = LAMenuStyle.make_button("Back")
	back_button.pressed.connect(_on_back)
	vbox.add_child(back_button)
	back_button.grab_focus()


## One credit row: "Name — License" with the source URL beneath it, dimmed.
func _make_entry(entry: Dictionary) -> Control:
	var row: VBoxContainer = VBoxContainer.new()
	row.add_theme_constant_override("separation", 1)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var name_label: Label = Label.new()
	name_label.text = "%s — %s" % [String(entry["name"]), String(entry["license"])]
	name_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	name_label.add_theme_color_override("font_color", LAMenuStyle.TEXT)
	name_label.add_theme_font_size_override("font_size", 13)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(name_label)

	var url_label: Label = Label.new()
	url_label.text = String(entry["url"])
	url_label.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	url_label.add_theme_color_override("font_color", LAMenuStyle.TEXT_DIM)
	url_label.add_theme_font_size_override("font_size", 11)
	url_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(url_label)

	return row


func _on_back() -> void:
	var err: int = get_tree().change_scene_to_file(MAIN_MENU_SCENE)
	if err != OK:
		push_error("CreditsMenu: failed to return to main menu (err=%d)" % err)
