class_name LAPauseMenu
extends CanvasLayer


const SPEEDS: Array[int] = [1, 2, 4, 8, 16]

const HelpOverlayScript: GDScript = preload("res://addons/local_agents/game/ui/PauseHelpOverlay.gd")

@onready var _speed_row: HBoxContainer = $Center/Panel/VBox/SpeedRow
@onready var _save_status: Label = $Center/Panel/VBox/SaveStatus
@onready var _resume_button: Button = $Center/Panel/VBox/Resume
@onready var _save_button: Button = $Center/Panel/VBox/Save
@onready var _help_button: Button = $Center/Panel/VBox/Help
@onready var _quit_button: Button = $Center/Panel/VBox/Quit

var _speed_buttons: Array[Button] = []


func _ready() -> void:
	_resume_button.pressed.connect(close)
	_save_button.pressed.connect(_on_save)
	_help_button.pressed.connect(open_controls_help)
	_quit_button.pressed.connect(_on_quit)
	for child in _speed_row.get_children():
		var b: Button = child as Button
		if b == null:
			continue
		_speed_buttons.append(b)
		b.pressed.connect(_on_speed_pressed.bind(int(b.text.trim_suffix("x"))))


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


## Open the in-sim Controls & help overlay on top of the pause menu. Returns the overlay node so a caller
## can screenshot / drive it; a Close button on the overlay frees it.
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


func _on_speed_pressed(n: int) -> void:
	set_time_scale(n)
	for b in _speed_buttons:
		b.button_pressed = (b.text == "%dx" % n)


## Forwards to LASimTimeAuthority, the one writer of the loop's step budget. No fallback: a second writer
## silently resets the rate.
func set_time_scale(n: int) -> void:
	var ctrl: LASimTimeAuthority = LASimTimeAuthority.active()
	if ctrl == null:
		push_error("LAPauseMenu: no LASimTimeAuthority in the scene — speed cannot be set.")
		return
	ctrl.set_steps_per_tick(clampi(n, 1, SPEEDS[SPEEDS.size() - 1]))


func _on_save() -> void:
	var ctrl: LAWorldSaveController = LAWorldSaveController.active()
	if ctrl == null:
		if _save_status != null:
			_save_status.text = "Save unavailable"
		return
	var err: int = ctrl.quick_save()
	if _save_status != null:
		_save_status.text = "World saved" if err == OK else "Save failed (err %d)" % err


func _on_quit() -> void:
	LAAppExit.request(self, 0)
