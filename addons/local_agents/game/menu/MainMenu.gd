class_name LAMainMenu
extends Control


const WORLD_SCENE: String = "res://addons/local_agents/game/VoxelWorld.tscn"
const SETTINGS_SCENE: String = "res://addons/local_agents/game/menu/SettingsMenu.tscn"
const HELP_SCENE: String = "res://addons/local_agents/game/menu/HelpMenu.tscn"
const CREDITS_SCENE: String = "res://addons/local_agents/game/menu/CreditsMenu.tscn"
const EXAMPLES_SCENE: String = "res://addons/local_agents/examples/DemoLauncher.tscn"

@onready var _new_button: Button = $Center/Panel/Column/NewCampaign
@onready var _continue_button: Button = $Center/Panel/Column/Continue
@onready var _sandbox_button: Button = $Center/Panel/Column/Sandbox
@onready var _settings_button: Button = $Center/Panel/Column/Settings
@onready var _models_button: Button = $Center/Panel/Column/Models
@onready var _examples_button: Button = $Center/Panel/Column/Examples
@onready var _help_button: Button = $Center/Panel/Column/Help
@onready var _credits_button: Button = $Center/Panel/Column/Credits
@onready var _quit_button: Button = $Center/Panel/Column/Quit


func _ready() -> void:
	# Dev shortcut: skip the menu straight into the sim (does not affect the --shoot menu capture).
	var direct: String = _direct_launch_arg()
	if direct != "":
		if direct == "campaign":
			GameMode.start_campaign()
		else:
			GameMode.start_sandbox()
		GameMode.apply(GameMode.settings)
		call_deferred("_change_scene", WORLD_SCENE)
		return

	_wire_actions()
	add_child(LAMenuShooter.new())


func _direct_launch_arg() -> String:
	for arg in OS.get_cmdline_user_args():
		if arg == "--campaign":
			return "campaign"
		if arg == "--sandbox" or arg == "--sim":
			return "sandbox"
	return ""


func _wire_actions() -> void:
	_new_button.pressed.connect(_on_new_campaign)

	_continue_button.disabled = not LAGameSave.has_save()
	_continue_button.tooltip_text = "Resume your last campaign" if not _continue_button.disabled else "No saved game yet"
	_continue_button.pressed.connect(_on_continue)

	_sandbox_button.pressed.connect(_on_sandbox)
	_settings_button.pressed.connect(func() -> void: _change_scene(SETTINGS_SCENE))
	_models_button.pressed.connect(func() -> void: LAMenuStyle.open_model_manager(self))
	_examples_button.pressed.connect(func() -> void: _change_scene(EXAMPLES_SCENE))
	_help_button.pressed.connect(func() -> void: _change_scene(HELP_SCENE))
	_credits_button.pressed.connect(func() -> void: _change_scene(CREDITS_SCENE))
	_quit_button.pressed.connect(_on_quit)

	# Keyboard entry point: focus the first enabled action so arrow keys / Tab navigate immediately.
	_new_button.grab_focus()


func _on_new_campaign() -> void:
	GameMode.start_campaign()
	GameMode.apply(GameMode.settings)
	_change_scene(WORLD_SCENE)


func _on_continue() -> void:
	var slot: String = LAGameSave.latest_slot()
	if slot == "":
		return
	GameMode.request_load(slot)
	GameMode.apply(GameMode.settings)
	_change_scene(WORLD_SCENE)


func _on_sandbox() -> void:
	GameMode.start_sandbox()
	GameMode.apply(GameMode.settings)
	_change_scene(WORLD_SCENE)


func _on_quit() -> void:
	LAAppExit.request(self, 0)


func _change_scene(path: String) -> void:
	var err: int = get_tree().change_scene_to_file(path)
	if err != OK:
		push_error("MainMenu: failed to change scene to %s (err=%d)" % [path, err])
