class_name LAPauseHelpOverlay
extends Control

## LAPauseHelpOverlay — the in-sim "Controls & help" panel opened from the Esc pause menu, so a player mid-game
## can re-check the bindings and mechanics without leaving the world. It embeds the SAME shared help hub
## (LAHelpTabs) the main-menu Help screen uses — Overview, the auto-generated Controls reference, and the
## browsable Codex — so there is one reference in the codebase, never a second in-sim copy. A dimmer swallows
## clicks and a Close button (or Esc) frees the overlay back to the pause menu. Runs while the tree is paused
## (its host CanvasLayer is PROCESS_MODE_ALWAYS, which it inherits). (Explicit types only — no ':=' .)

const OVERLAY_DIM: Color = Color(0.0, 0.0, 0.02, 0.72)
const PANEL_WIDTH: float = 720.0
const CONTENT_HEIGHT: float = 440.0


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build()


func _build() -> void:
	var dim: ColorRect = ColorRect.new()
	dim.color = OVERLAY_DIM
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)

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

	vbox.add_child(LAMenuStyle.make_title("Controls & help"))

	vbox.add_child(LAHelpTabs.build(PANEL_WIDTH, CONTENT_HEIGHT, "controls"))

	var close_button: Button = LAMenuStyle.make_button("Close")
	close_button.pressed.connect(queue_free)
	vbox.add_child(close_button)
	close_button.grab_focus()


# Esc closes the overlay (returns to the pause menu). Consumed so the pause menu doesn't also react.
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo \
			and (event as InputEventKey).keycode == KEY_ESCAPE:
		get_viewport().set_input_as_handled()
		queue_free()
