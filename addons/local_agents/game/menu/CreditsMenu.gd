class_name LACreditsMenu
extends Control


const MAIN_MENU_SCENE: String = "res://addons/local_agents/game/menu/MainMenu.tscn"

## Grouped credits. Each group has a heading and a list of entries; each entry is name · license · url.
const CREDIT_GROUPS: Array = [
	{
		"title": "Engine & tools",
		"entries": [
			{"name": "Godot Engine", "license": "MIT", "url": "https://godotengine.org"},
			{"name": "godot-cpp (GDExtension bindings)", "license": "MIT", "url": "https://github.com/godotengine/godot-cpp"},
			{"name": "godot_voxel by Zylann / Marc Gilleron", "license": "MIT", "url": "https://github.com/Zylann/godot_voxel"},
			{"name": "llama.cpp by the ggml authors", "license": "MIT", "url": "https://github.com/ggml-org/llama.cpp"},
			{"name": "whisper.cpp by the ggml authors", "license": "MIT", "url": "https://github.com/ggml-org/whisper.cpp"},
		],
	},
	{
		"title": "Art",
		"entries": [
			{"name": "Cube Pets & Nature Kit by Kenney", "license": "CC0", "url": "https://kenney.nl"},
			{"name": "Creatures & character by Quaternius", "license": "CC0", "url": "https://quaternius.com"},
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
			{"name": "Qwen3 (0.6B to 14B)", "license": "Apache-2.0", "url": "https://huggingface.co/Qwen"},
			{"name": "Qwen2.5-3B-Instruct", "license": "Qwen Research License", "url": "https://huggingface.co/Qwen/Qwen2.5-3B-Instruct"},
			{"name": "FunctionGemma-270M (Google, Gemma 3)", "license": "Gemma Terms of Use", "url": "https://ai.google.dev/gemma/terms"},
		],
	},
]

@onready var _groups: VBoxContainer = $Center/Panel/Column/Scroll/Groups
@onready var _back_button: Button = $Center/Panel/Column/Back


func _ready() -> void:
	_fill_groups()
	_back_button.pressed.connect(_on_back)
	_back_button.grab_focus()
	add_child(LAMenuShooter.new())


func _fill_groups() -> void:
	for group in CREDIT_GROUPS:
		var heading: Label = Label.new()
		heading.text = String(group["title"])
		heading.add_theme_color_override("font_color", LAMenuStyle.ACCENT)
		heading.add_theme_font_size_override("font_size", 16)
		_groups.add_child(heading)

		for entry in group["entries"]:
			_groups.add_child(_make_entry(entry))

		var gap: Control = Control.new()
		gap.custom_minimum_size = Vector2(0.0, 6.0)
		_groups.add_child(gap)


## One credit row: "Name, License" with the source URL beneath it, dimmed.
func _make_entry(entry: Dictionary) -> Control:
	var row: VBoxContainer = VBoxContainer.new()
	row.add_theme_constant_override("separation", 1)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var name_label: Label = Label.new()
	name_label.text = "%s, %s" % [String(entry["name"]), String(entry["license"])]
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
