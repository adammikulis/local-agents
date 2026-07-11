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
var _timeline: Node = null         # optional — LAVoxelTimeline (reverse/fork via the snapshot ring)
var _reversing: bool = false       # mirror of the timeline's reverse state, for the HUD
var _label: Label = null
var _toast: Label = null           # fading time-travel "achievement" pop-up
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


## Optional: the timeline (reverse/fork). J toggles reversing; the HUD reflects its state.
func set_timeline(timeline: Node) -> void:
	_timeline = timeline
	if _timeline != null and _timeline.has_signal("timeline_changed"):
		_timeline.timeline_changed.connect(_on_timeline_changed)
	if _timeline != null and _timeline.has_signal("achievement"):
		_timeline.achievement.connect(_on_achievement)


## Pop a tongue-in-cheek time-travel "achievement" toast (from the timeline's rewind-count milestones), fading it.
func _on_achievement(title: String, body: String) -> void:
	if _toast == null:
		return
	_toast.text = "%s\n%s" % [title, body]
	_toast.modulate.a = 1.0
	var tw: Tween = create_tween()
	tw.tween_interval(4.5)
	tw.tween_property(_toast, "modulate:a", 0.0, 1.5)


func _on_timeline_changed(count: int, _cursor: int, reversing: bool) -> void:
	_reversing = reversing
	_update_hud(count)


## A forward time action (play/faster/slower/pause) first cancels any active reverse scrub — resuming from the
## scrubbed point forks the timeline (the abandoned future is dropped by the timeline).
func _exit_reverse() -> void:
	if _reversing and _timeline != null and _timeline.has_method("stop_reverse"):
		_timeline.stop_reverse()
	_reversing = false


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
	# Time-travel achievement toast — centred just below the speed pill, faded in/out by _on_achievement.
	var toast_center: CenterContainer = CenterContainer.new()
	toast_center.set_anchors_preset(Control.PRESET_TOP_WIDE)
	toast_center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(toast_center)
	_toast = Label.new()
	_toast.add_theme_color_override("font_color", Color(1.0, 0.92, 0.55, 1.0))
	_toast.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.9))
	_toast.add_theme_constant_override("outline_size", 6)
	_toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast.position = Vector2(0.0, 44.0)
	_toast.modulate.a = 0.0
	toast_center.add_child(_toast)


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
			_exit_reverse()
			_idx = PLAY_IDX
			_paused = false
			_apply()
		KEY_J:
			# Reverse-scrub toggle (snapshot rewind). Forking happens when a forward action resumes from here.
			if _timeline != null and _timeline.has_method("toggle_reverse"):
				_timeline.toggle_reverse()
		_:
			return
	get_viewport().set_input_as_handled()


func toggle_pause() -> void:
	_exit_reverse()
	_paused = not _paused
	_apply()


func play() -> void:
	_exit_reverse()
	_paused = false
	_apply()


func faster() -> void:
	_exit_reverse()
	_paused = false
	_idx = mini(_idx + 1, SPEEDS.size() - 1)
	_apply()


func slower() -> void:
	_exit_reverse()
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


func _update_hud(rev_count: int = -1) -> void:
	if _label == null:
		return
	if _reversing:
		# Explicit: rewind is approximate — it restores the LIFE, not the environment (perf-over-parity).
		var tail: String = "" if rev_count < 0 else ("  ·  %d left" % rev_count)
		_label.text = "◀◀  REWIND  (life reverts · world keeps flowing)%s" % tail
	elif _paused:
		_label.text = "‖  PAUSED"
	else:
		var s: float = SPEEDS[_idx]
		var num: String = ("%.2f" % s).rstrip("0").rstrip(".") if s < 1.0 else str(int(round(s)))
		_label.text = ("▶  %s×" % num) if s >= 1.0 else ("◗  %s×" % num)
