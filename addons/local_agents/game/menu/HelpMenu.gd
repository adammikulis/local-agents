class_name LAHelpMenu
extends Control

## The help & reference screen. Node tree and styling live in HelpMenu.tscn; the Tabs host is filled with
## the shared help hub (LAHelpTabs), which the in-sim pause menu also embeds.

const MAIN_MENU_SCENE: String = "res://addons/local_agents/game/menu/MainMenu.tscn"

const PANEL_WIDTH: float = 720.0
const CONTENT_HEIGHT: float = 470.0

@onready var _tabs: VBoxContainer = $Center/Panel/Column/Tabs
@onready var _back_button: Button = $Center/Panel/Column/Back


func _ready() -> void:
	_tabs.add_child(LAHelpTabs.build(PANEL_WIDTH, CONTENT_HEIGHT, _start_tab_arg()))
	_back_button.pressed.connect(_on_back)
	_back_button.grab_focus()
	add_child(LAMenuShooter.new())


## Which tab to open on: `--help-tab=controls|codex|overview`, default overview.
func _start_tab_arg() -> String:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--help-tab="):
			return arg.substr("--help-tab=".length())
	return "overview"


func _on_back() -> void:
	var err: int = get_tree().change_scene_to_file(MAIN_MENU_SCENE)
	if err != OK:
		push_error("HelpMenu: failed to return to main menu (err=%d)" % err)
