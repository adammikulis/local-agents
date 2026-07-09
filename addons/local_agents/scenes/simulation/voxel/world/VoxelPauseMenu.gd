class_name LAVoxelPauseMenu
extends CanvasLayer

## LAVoxelPauseMenu — the Esc pause menu. Esc opens it from ANY state and PAUSES the sim
## (get_tree().paused); Esc again or the Resume button closes it and unpauses; Quit exits. Built in code
## (no .tscn) as a self-contained CanvasLayer so the input controller can host it with one add_child. The
## layer runs PROCESS_MODE_ALWAYS so its buttons + Esc still work while the tree is paused. It also carries
## the optional in-menu fast-forward control (Contract 10) — the speed row sets Engine.time_scale so the
## sim runs N steps per render frame. (Explicit types only — no ':=' inferred typing.)

const OVERLAY_DIM: Color = Color(0.0, 0.0, 0.02, 0.62)
const PANEL_BG: Color = Color(0.06, 0.08, 0.12, 0.96)
const ACCENT: Color = Color(0.55, 0.72, 1.0)
const SPEEDS: Array[int] = [1, 2, 4, 8, 16]

const HelpOverlayScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/world/PauseHelpOverlay.gd")

var _panel: Control = null
var _speed_buttons: Array[Button] = []


func _init() -> void:
	# ALWAYS so Esc/buttons keep firing once get_tree().paused is set; draw above the HUD.
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = 128
	visible = false


func _ready() -> void:
	_build_ui()


func _build_ui() -> void:
	# Full-screen dimmer that also swallows clicks so nothing leaks through to the world behind the menu.
	var dim: ColorRect = ColorRect.new()
	dim.color = OVERLAY_DIM
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)

	var center: CenterContainer = CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	var panel: PanelContainer = PanelContainer.new()
	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = PANEL_BG
	style.set_corner_radius_all(10)
	style.set_border_width_all(2)
	style.border_color = ACCENT
	style.set_content_margin_all(28.0)
	panel.add_theme_stylebox_override("panel", style)
	center.add_child(panel)
	_panel = panel

	var vbox: VBoxContainer = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 14)
	vbox.custom_minimum_size = Vector2(280.0, 0.0)
	panel.add_child(vbox)

	var title: Label = Label.new()
	title.text = "Paused"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 32)
	title.add_theme_color_override("font_color", ACCENT)
	vbox.add_child(title)

	var resume: Button = Button.new()
	resume.text = "Resume game"
	resume.custom_minimum_size = Vector2(0.0, 44.0)
	resume.pressed.connect(close)
	vbox.add_child(resume)

	# Optional in-menu fast-forward (Contract 10): pick how many sim steps run per render frame.
	var speed_label: Label = Label.new()
	speed_label.text = "Time speed"
	speed_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	speed_label.add_theme_color_override("font_color", Color(0.75, 0.8, 0.9))
	vbox.add_child(speed_label)

	var speed_row: HBoxContainer = HBoxContainer.new()
	speed_row.alignment = BoxContainer.ALIGNMENT_CENTER
	speed_row.add_theme_constant_override("separation", 6)
	vbox.add_child(speed_row)
	for n in SPEEDS:
		var b: Button = Button.new()
		b.text = "%dx" % n
		b.toggle_mode = true
		b.custom_minimum_size = Vector2(44.0, 34.0)
		b.button_pressed = (n == 1)
		b.pressed.connect(_on_speed_pressed.bind(n))
		speed_row.add_child(b)
		_speed_buttons.append(b)

	var help: Button = Button.new()
	help.text = "Controls & help"
	help.custom_minimum_size = Vector2(0.0, 44.0)
	help.pressed.connect(open_controls_help)
	vbox.add_child(help)

	var quit: Button = Button.new()
	quit.text = "Quit game"
	quit.custom_minimum_size = Vector2(0.0, 44.0)
	quit.pressed.connect(_on_quit)
	vbox.add_child(quit)


## Open the menu. `pause` (default true) also pauses the sim; the screenshot harness passes false so it can
## render the overlay without freezing the capture loop.
func open(pause: bool = true) -> void:
	visible = true
	if pause:
		get_tree().paused = true


func close() -> void:
	visible = false
	get_tree().paused = false


func toggle() -> void:
	if visible:
		close()
	else:
		open()


func is_open() -> bool:
	return visible


## Open the in-sim Controls & help overlay (the shared help hub) on top of the pause menu. Reused by the
## pause button and the --help-shot verification path; a Close button on the overlay frees it. Returns the
## overlay node so a caller can screenshot / drive it.
func open_controls_help() -> Control:
	var overlay: Control = HelpOverlayScript.new()
	overlay.name = "ControlsHelpOverlay"
	add_child(overlay)
	return overlay


# Esc while the menu is open closes it (and unpauses). Consumed so nothing else reacts to the same key.
func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventKey and event.pressed and not event.echo \
			and (event as InputEventKey).keycode == KEY_ESCAPE:
		close()
		get_viewport().set_input_as_handled()


# Fast-forward: run N sim steps per render frame by scaling the engine clock (fixed per-step physics, just
# more physics ticks per frame). Also lift the per-frame physics-tick cap so the engine may actually run N.
func _on_speed_pressed(n: int) -> void:
	set_time_scale(n)
	for b in _speed_buttons:
		b.button_pressed = (b.text == "%dx" % n)


## Reusable fast-forward setter (also called by the CLI --fast path). Caps N to the SPEEDS range.
func set_time_scale(n: int) -> void:
	var mult: int = clampi(n, 1, SPEEDS[SPEEDS.size() - 1])
	Engine.time_scale = float(mult)
	Engine.max_physics_steps_per_frame = maxi(8, mult)


func _on_quit() -> void:
	get_tree().quit(0)
