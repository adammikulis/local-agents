class_name LAVoxelTimeControl
extends CanvasLayer

## Player time-dilation controls (perf-first: event-driven, zero per-frame cost). The single authoritative
## owner of the sim's playback rate — pause, slow-motion, real-time, and fast-forward — applied via
## Engine.time_scale (speed) and get_tree().paused (hard pause). Runs PROCESS_MODE_ALWAYS so the keys and the
## HUD keep working while the tree is paused (that is what lets Space un-pause).
##
## Keys:  Space = pause / play toggle · , = slower · . = faster · Home = reset to 1×.
## REVERSE + timeline FORK plug in here later (the snapshot ring-buffer): reverse becomes another speed state
## driven by restoring snapshots, and this stays the one place the HUD + rate live. This module is the
## speed/pause half; it exposes current_speed()/is_paused() + a speed_changed signal for that next layer.

const SPEEDS: Array[float] = [0.25, 0.5, 1.0, 2.0, 4.0, 8.0]
const PLAY_IDX: int = 2   # 1.0×

signal speed_changed(paused: bool, speed: float)

var _idx: int = PLAY_IDX
var _paused: bool = false
var _camera: Node = null           # optional — to yield Space to the fly-drone's lift control
var _label: Label = null
var _panel: PanelContainer = null


func _init() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = 60


func _ready() -> void:
	_build_hud()
	_apply()


## Optional: the camera rig, so Space pauses only when NOT flying the drone (fly uses Space for lift).
func set_camera(camera: Node) -> void:
	_camera = camera


func _build_hud() -> void:
	_panel = PanelContainer.new()
	_panel.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Small, centred pill at the top; unobtrusive.
	var center: CenterContainer = CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_TOP_WIDE)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)
	_label = Label.new()
	_label.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 0.92))
	_label.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.85))
	_label.add_theme_constant_override("outline_size", 5)
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.position = Vector2(0.0, 8.0)
	center.add_child(_label)


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var key: InputEventKey = event
	if not key.pressed or key.echo:
		return
	match key.keycode:
		KEY_SPACE:
			# Yield to the fly-drone (Space = lift) when flying, so time-pause never fights it.
			if _camera != null and _camera.has_method("is_fly") and _camera.is_fly():
				return
			toggle_pause()
		KEY_PERIOD:
			faster()
		KEY_COMMA:
			slower()
		KEY_HOME:
			_idx = PLAY_IDX
			_paused = false
			_apply()
		_:
			return
	get_viewport().set_input_as_handled()


func toggle_pause() -> void:
	_paused = not _paused
	_apply()


func play() -> void:
	_paused = false
	_apply()


func faster() -> void:
	_paused = false
	_idx = mini(_idx + 1, SPEEDS.size() - 1)
	_apply()


func slower() -> void:
	_paused = false
	_idx = maxi(_idx - 1, 0)
	_apply()


func is_paused() -> bool:
	return _paused


## The effective playback rate the sim is running at (0 while paused). Read by the HUD + the snapshot layer.
func current_speed() -> float:
	return 0.0 if _paused else SPEEDS[_idx]


func _apply() -> void:
	get_tree().paused = _paused
	if not _paused:
		Engine.time_scale = SPEEDS[_idx]
		# Let physics keep up when fast-forwarding (more sub-steps per frame at high scale).
		Engine.max_physics_steps_per_frame = maxi(8, int(ceil(SPEEDS[_idx])) * 8)
	_update_hud()
	speed_changed.emit(_paused, current_speed())


func _update_hud() -> void:
	if _label == null:
		return
	if _paused:
		_label.text = "‖  PAUSED"
	else:
		var s: float = SPEEDS[_idx]
		var num: String = ("%.2f" % s).rstrip("0").rstrip(".") if s < 1.0 else str(int(round(s)))
		_label.text = ("▶  %s×" % num) if s >= 1.0 else ("◗  %s×" % num)
