class_name LAMainMenu
extends Control

## LAMainMenu — the game's title screen and front door. Six actions, top to bottom:
##   New campaign · Continue · Sandbox · Settings · Help · Quit.
##
## "New campaign" and "Sandbox" both launch the SAME sim scene (VoxelWorld.tscn) via
## change_scene_to_file, differing only in the mode flag they set on the GameMode autoload before
## the switch (campaign = progression gating on, sandbox = off). The mode + the active settings ride
## across the scene change on GameMode, which the sim reads on boot (wiring is a later task).
## "Continue" is enabled only when LAGameSave.has_save() is true (a stub that returns false until the
## save system exists). "Settings" and "Help" swap to their own scenes (each has a Back button).
##
## The UI is built in code to match the in-sim pause menu / view-controls styling (see LAMenuStyle).
## Fully keyboard-navigable: the first button grabs focus and arrow keys/Tab move between buttons.
## Dev shortcut: pass `--sim` (or `--sandbox` / `--campaign`) as a user arg to boot straight past the
## menu into the sim. (Explicit types only — no ':=' inferred typing.)

const WORLD_SCENE: String = "res://addons/local_agents/scenes/simulation/voxel/VoxelWorld.tscn"
const SETTINGS_SCENE: String = "res://addons/local_agents/scenes/menu/SettingsMenu.tscn"
const HELP_SCENE: String = "res://addons/local_agents/scenes/menu/HelpMenu.tscn"

var _continue_button: Button = null


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

	_build_ui()
	add_child(LAMenuShooter.new())


func _direct_launch_arg() -> String:
	for arg in OS.get_cmdline_user_args():
		if arg == "--campaign":
			return "campaign"
		if arg == "--sandbox" or arg == "--sim":
			return "sandbox"
	return ""


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
	vbox.add_theme_constant_override("separation", 12)
	vbox.custom_minimum_size = Vector2(320.0, 0.0)
	panel.add_child(vbox)

	vbox.add_child(LAMenuStyle.make_title("Local Agents"))
	vbox.add_child(LAMenuStyle.make_caption("A living world, simulated locally"))

	var spacer: Control = Control.new()
	spacer.custom_minimum_size = Vector2(0.0, 8.0)
	vbox.add_child(spacer)

	var new_button: Button = LAMenuStyle.make_button("New campaign")
	new_button.pressed.connect(_on_new_campaign)
	vbox.add_child(new_button)

	_continue_button = LAMenuStyle.make_button("Continue")
	_continue_button.disabled = not LAGameSave.has_save()
	_continue_button.tooltip_text = "Resume your last campaign" if not _continue_button.disabled else "No saved game yet"
	_continue_button.pressed.connect(_on_continue)
	vbox.add_child(_continue_button)

	var sandbox_button: Button = LAMenuStyle.make_button("Sandbox")
	sandbox_button.tooltip_text = "Free play with no progression gating"
	sandbox_button.pressed.connect(_on_sandbox)
	vbox.add_child(sandbox_button)

	var settings_button: Button = LAMenuStyle.make_button("Settings")
	settings_button.pressed.connect(func() -> void: _change_scene(SETTINGS_SCENE))
	vbox.add_child(settings_button)

	var help_button: Button = LAMenuStyle.make_button("Help")
	help_button.pressed.connect(func() -> void: _change_scene(HELP_SCENE))
	vbox.add_child(help_button)

	var quit_button: Button = LAMenuStyle.make_button("Quit")
	quit_button.pressed.connect(_on_quit)
	vbox.add_child(quit_button)

	# Keyboard entry point: focus the first enabled action so arrow keys / Tab navigate immediately.
	new_button.grab_focus()


func _on_new_campaign() -> void:
	GameMode.start_campaign()
	GameMode.apply(GameMode.settings)
	_change_scene(WORLD_SCENE)


func _on_continue() -> void:
	# Save loading is not built yet; Continue is disabled unless a save exists. When it does, a
	# campaign resume is the intended behaviour, so launch campaign mode.
	GameMode.start_campaign()
	GameMode.apply(GameMode.settings)
	_change_scene(WORLD_SCENE)


func _on_sandbox() -> void:
	GameMode.start_sandbox()
	GameMode.apply(GameMode.settings)
	_change_scene(WORLD_SCENE)


func _on_quit() -> void:
	get_tree().quit(0)


func _change_scene(path: String) -> void:
	var err: int = get_tree().change_scene_to_file(path)
	if err != OK:
		push_error("MainMenu: failed to change scene to %s (err=%d)" % [path, err])
