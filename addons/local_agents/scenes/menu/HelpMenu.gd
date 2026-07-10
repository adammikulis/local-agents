class_name LAHelpMenu
extends Control

## LAHelpMenu — the persistent help & reference screen reached from the main menu, for a returning player who
## wants to re-acquaint from the screen (distinct from the one-time guided tutorial). It hosts the shared help
## hub (LAHelpTabs): an Overview blurb, the auto-generated Controls reference (LAControlsReference, straight
## from LAHotkeyRegistry so it never drifts from the real keys), and the browsable Codex (LAHelpCodex). The
## SAME hub is embedded in the in-sim pause menu. Built in code to match the shared menu styling (LAMenuStyle);
## keyboard-navigable, with a Back button that returns to the main menu.
##
## Screenshot harness: pass `-- --shoot=<png> [--help-tab=controls|codex]` to open on a given tab and capture
## it (LAMenuShooter). (Explicit types only — no ':=' inferred typing.)

const MAIN_MENU_SCENE: String = "res://addons/local_agents/scenes/menu/MainMenu.tscn"

const PANEL_WIDTH: float = 720.0
const CONTENT_HEIGHT: float = 470.0


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
	vbox.custom_minimum_size = Vector2(PANEL_WIDTH, 0.0)
	panel.add_child(vbox)

	vbox.add_child(LAMenuStyle.make_title("Help & reference"))

	vbox.add_child(LAHelpTabs.build(PANEL_WIDTH, CONTENT_HEIGHT, _start_tab_arg()))

	var back_button: Button = LAMenuStyle.make_button("Back")
	back_button.pressed.connect(_on_back)
	vbox.add_child(back_button)
	back_button.grab_focus()


## Which tab to open on (screenshot / deep-link aid): `--help-tab=controls|codex|overview`, default overview.
func _start_tab_arg() -> String:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--help-tab="):
			return arg.substr("--help-tab=".length())
	return "overview"


func _on_back() -> void:
	var err: int = get_tree().change_scene_to_file(MAIN_MENU_SCENE)
	if err != OK:
		push_error("HelpMenu: failed to return to main menu (err=%d)" % err)
