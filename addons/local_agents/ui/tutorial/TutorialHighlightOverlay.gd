class_name LATutorialHighlightOverlay
extends Control

## Full-screen guided-tutorial overlay: dims the whole viewport, cuts a bright "spotlight" hole around a
## target rectangle, outlines it, points an arrow at it, and floats a text callout (title + body +
## Back / Skip / Next buttons + a "don't show again" checkbox) beside it. The spotlight animates smoothly
## between targets and degrades gracefully when a target is momentarily null or off-screen (it just dims
## and centers the callout). Purely presentational: it owns no step logic. An LATutorialSequencer drives
## it via show_step()/finish() and listens to its button signals. Reusable and game-agnostic. The callout
## widgets are TutorialHighlightOverlay.tscn.
## (Explicit types only. No ':=' inferred typing.)

signal next_pressed
signal back_pressed
signal skip_pressed
signal dont_show_toggled(enabled: bool)

const DIM_ALPHA: float = 0.62                 # darkness of the masked area at full fade-in
const OUTLINE_COLOR: Color = Color(1.0, 0.85, 0.28, 1.0)
const OUTLINE_WIDTH: float = 3.0
const CORNER: float = 10.0                    # spotlight corner radius
const FADE_SPEED: float = 6.0                 # dim alpha units/sec
const RECT_LERP: float = 14.0                 # spotlight rect chase speed (higher = snappier)
const PULSE_HZ: float = 1.4                   # outline pulse frequency
const CALLOUT_MARGIN: float = 24.0            # keep-on-screen inset for the callout
const ARROW_SIZE: float = 14.0

var _target_rect: Rect2 = Rect2()             # where the spotlight wants to be (screen space)
var _current_rect: Rect2 = Rect2()            # where it is now (chases _target_rect)
var _has_target: bool = false                 # false -> no spotlight, just dim + centered callout
var _rect_valid: bool = false                 # _current_rect has been seeded (first show snaps, not lerps)
var _dim_alpha: float = 0.0                   # 0..1 fade envelope
var _fading_out: bool = false
var _pulse_t: float = 0.0

@onready var _callout: PanelContainer = $Callout
@onready var _title_label: Label = $Callout/VBox/Title
@onready var _body_label: Label = $Callout/VBox/Body
@onready var _progress_label: Label = $Callout/VBox/Progress
@onready var _dont_show_check: CheckBox = $Callout/VBox/Row/DontShow
@onready var _back_btn: Button = $Callout/VBox/Row/Back
@onready var _skip_btn: Button = $Callout/VBox/Row/Skip
@onready var _next_btn: Button = $Callout/VBox/Row/Next


func _on_dont_show_toggled(on: bool) -> void:
	dont_show_toggled.emit(on)


func _on_back_pressed() -> void:
	back_pressed.emit()


func _on_skip_pressed() -> void:
	skip_pressed.emit()


func _on_next_pressed() -> void:
	next_pressed.emit()


## Show a step. `target_rect` is the spotlight (ignored if `has_target` is false). `next_visible` hides the
## Next button for steps that only advance on a target press / predicate. `dont_show_on` seeds the checkbox.
func show_step(target_rect: Rect2, has_target: bool, title: String, body: String, progress: String,
		can_back: bool, next_label: String, next_visible: bool, dont_show_on: bool) -> void:
	visible = true
	_fading_out = false
	_target_rect = target_rect
	_has_target = has_target and _is_rect_sane(target_rect)
	if not _rect_valid and _has_target:
		_current_rect = _target_rect            # first target snaps in rather than sliding from Rect2()
		_rect_valid = true
	_title_label.text = title
	_title_label.visible = title != ""
	_body_label.text = body
	_progress_label.text = progress
	_progress_label.visible = progress != ""
	_back_btn.disabled = not can_back
	_next_btn.visible = next_visible
	_next_btn.text = next_label
	_dont_show_check.set_pressed_no_signal(dont_show_on)
	set_process(true)
	queue_redraw()


## Update just the spotlight target (e.g. a world point that moves, or a control that relayouts) without
## resetting the callout. Cheap enough to call every frame from the sequencer.
func update_target(target_rect: Rect2, has_target: bool) -> void:
	_target_rect = target_rect
	_has_target = has_target and _is_rect_sane(target_rect)
	if not _rect_valid and _has_target:
		_current_rect = _target_rect
		_rect_valid = true


func set_dont_show_visible(v: bool) -> void:
	if _dont_show_check != null:
		_dont_show_check.visible = v


## Begin fading the overlay out; hides itself once transparent.
func finish() -> void:
	_fading_out = true
	set_process(true)


func _is_rect_sane(r: Rect2) -> bool:
	# Guard against NaN/inf and degenerate/off-screen rects so a missing target never crashes the draw.
	if not (is_finite(r.position.x) and is_finite(r.position.y) and is_finite(r.size.x) and is_finite(r.size.y)):
		return false
	if r.size.x <= 1.0 or r.size.y <= 1.0:
		return false
	var vp: Rect2 = Rect2(Vector2.ZERO, size)
	return vp.intersects(r)


func _process(delta: float) -> void:
	_pulse_t += delta
	var goal: float = 0.0 if _fading_out else 1.0
	_dim_alpha = move_toward(_dim_alpha, goal, FADE_SPEED * delta)
	if _has_target:
		var t: float = clampf(RECT_LERP * delta, 0.0, 1.0)
		_current_rect.position = _current_rect.position.lerp(_target_rect.position, t)
		_current_rect.size = _current_rect.size.lerp(_target_rect.size, t)
	_layout_callout()
	queue_redraw()
	if _fading_out and _dim_alpha <= 0.001:
		visible = false
		set_process(false)


func _layout_callout() -> void:
	if _callout == null:
		return
	var cs: Vector2 = _callout.get_combined_minimum_size()
	_callout.size = cs
	var vp: Vector2 = size
	var pos: Vector2
	if _has_target:
		var spot: Rect2 = _padded_spotlight()
		# Prefer below the spotlight; flip above if it would run off the bottom.
		var below_y: float = spot.position.y + spot.size.y + 18.0
		if below_y + cs.y + CALLOUT_MARGIN <= vp.y:
			pos = Vector2(spot.position.x + spot.size.x * 0.5 - cs.x * 0.5, below_y)
		else:
			pos = Vector2(spot.position.x + spot.size.x * 0.5 - cs.x * 0.5,
				spot.position.y - cs.y - 18.0)
	else:
		pos = (vp - cs) * 0.5
	pos.x = clampf(pos.x, CALLOUT_MARGIN, maxf(CALLOUT_MARGIN, vp.x - cs.x - CALLOUT_MARGIN))
	pos.y = clampf(pos.y, CALLOUT_MARGIN, maxf(CALLOUT_MARGIN, vp.y - cs.y - CALLOUT_MARGIN))
	_callout.position = pos


func _padded_spotlight() -> Rect2:
	return _current_rect.grow(6.0)


func _draw() -> void:
	if _dim_alpha <= 0.001:
		return
	var vp: Rect2 = Rect2(Vector2.ZERO, size)
	var dim: Color = Color(0.0, 0.0, 0.0, DIM_ALPHA * _dim_alpha)
	if not _has_target:
		draw_rect(vp, dim, true)
		return

	# Dim everything except the spotlight hole by drawing four bands around it (a rectangular cutout is
	# far cheaper than per-pixel masking and reads cleanly with the rounded outline on top).
	var s: Rect2 = _padded_spotlight()
	s = s.intersection(vp)
	var top: Rect2 = Rect2(0, 0, vp.size.x, s.position.y)
	var bottom: Rect2 = Rect2(0, s.position.y + s.size.y, vp.size.x, vp.size.y - (s.position.y + s.size.y))
	var left: Rect2 = Rect2(0, s.position.y, s.position.x, s.size.y)
	var right: Rect2 = Rect2(s.position.x + s.size.x, s.position.y, vp.size.x - (s.position.x + s.size.x), s.size.y)
	draw_rect(top, dim, true)
	draw_rect(bottom, dim, true)
	draw_rect(left, dim, true)
	draw_rect(right, dim, true)

	# Pulsing outline around the hole.
	var pulse: float = 0.5 + 0.5 * sin(_pulse_t * TAU * PULSE_HZ)
	var oc: Color = OUTLINE_COLOR
	oc.a = (0.55 + 0.45 * pulse) * _dim_alpha
	_draw_rounded_outline(s, CORNER, oc, OUTLINE_WIDTH)

	# Arrow from the callout toward the spotlight.
	_draw_arrow(s, oc)


func _draw_rounded_outline(r: Rect2, radius: float, color: Color, width: float) -> void:
	var rad: float = minf(radius, minf(r.size.x, r.size.y) * 0.5)
	var pts: PackedVector2Array = PackedVector2Array()
	var segs: int = 5
	var corners: Array = [
		Vector2(r.position.x + r.size.x - rad, r.position.y + rad),               # top-right center
		Vector2(r.position.x + r.size.x - rad, r.position.y + r.size.y - rad),    # bottom-right
		Vector2(r.position.x + rad, r.position.y + r.size.y - rad),               # bottom-left
		Vector2(r.position.x + rad, r.position.y + rad),                          # top-left
	]
	var start_ang: Array = [-PI * 0.5, 0.0, PI * 0.5, PI]
	for i in range(4):
		var c: Vector2 = corners[i]
		for j in range(segs + 1):
			var a: float = start_ang[i] + (PI * 0.5) * (float(j) / float(segs))
			pts.append(c + Vector2(cos(a), sin(a)) * rad)
	pts.append(pts[0])
	draw_polyline(pts, color, width, true)


func _draw_arrow(spot: Rect2, color: Color) -> void:
	if _callout == null or not _callout.visible:
		return
	var crect: Rect2 = Rect2(_callout.position, _callout.size)
	var from: Vector2 = crect.get_center()
	var to: Vector2 = spot.get_center()
	var dir: Vector2 = (to - from)
	if dir.length() < 1.0:
		return
	dir = dir.normalized()
	# Tail starts at the callout edge, head stops just short of the spotlight edge.
	var tail: Vector2 = from + dir * (minf(crect.size.x, crect.size.y) * 0.5 + 4.0)
	var head: Vector2 = to - dir * (minf(spot.size.x, spot.size.y) * 0.5 + 6.0)
	if (head - tail).length() < 6.0:
		return
	draw_line(tail, head, color, 3.0, true)
	var perp: Vector2 = dir.orthogonal()
	var p1: Vector2 = head - dir * ARROW_SIZE + perp * (ARROW_SIZE * 0.55)
	var p2: Vector2 = head - dir * ARROW_SIZE - perp * (ARROW_SIZE * 0.55)
	draw_colored_polygon(PackedVector2Array([head, p1, p2]), color)
