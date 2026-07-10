class_name LATrailerDirector
extends Node

## SCENE SCRIPTER for capturing trailer/marketing shots deterministically (docs/TRAILER.md). One shot per run:
##   scripts/capture_trailer.sh <shot>    (drives Godot movie-maker → H.264 mp4 in trailers/)
##
## A shot is TWO tracks: a keyframed CAMERA PATH ({f,pos,look} world-space, interpolated + eased each frame) and
## timed EVENTS ({f,do,arg} — spawn a disaster, fling a meteor, fast-forward). The director takes over the
## camera (freezes the RTS rig + drives its Transform3D directly — precise cinematic moves the game modes can't
## give) and hides ALL UI, then auto-quits. Arc per your brief: OPEN CLOSE on chaos (you don't know it's a
## planet), BACK OUT as the chaos grows, END on the whole planet + sun with a meteor sweeping in from the side
## opposite the sun. `fast N` beats time-lapse the presim so a shot lines up to the state it needs.
## (Explicit types; no ':=' .)

const FPS: float = 60.0

var _world: Node = null
var _camera: Camera3D = null          # LAVoxelCameraRig (is a Camera3D) — frozen + driven directly
var _disasters: Node = null
var _input: Node = null
var _body: Node = null                # LAPlanetBody
var _hud_root: CanvasLayer = null

var _shot: String = ""
var _frame: int = 0
var _cam_keys: Array = []              # [{f:int, pos:Vector3, look:Vector3}]
var _events: Array = []               # [{f:int, do:String, arg}]
var _ev_i: int = 0
var _end_frame: int = 0
var _active: bool = false
var _tracked: Node3D = null           # a spawned actor (volcano) the camera can bias toward


func begin(world: Node, camera: Camera3D, disasters: Node, input: Node, body: Node, hud_root: CanvasLayer, shot: String) -> void:
	_world = world
	_camera = camera
	_disasters = disasters
	_input = input
	_body = body
	_hud_root = hud_root
	_shot = shot
	_hide_all_ui()
	# Freeze the RTS rig so its per-frame focus/orbit rebuild doesn't fight our direct Transform3D writes.
	if _camera != null:
		_camera.set_process(false)
		_camera.set_physics_process(false)
	_build_shot(shot)
	if _cam_keys.is_empty():
		push_warning("TrailerDirector: unknown shot '%s'" % shot)
		return
	_end_frame = int(_cam_keys.back().get("f", 0)) + 30
	_active = true
	print("TRAILER_SHOT_BEGIN=%s end_frame=%d" % [shot, _end_frame])


func _process(_delta: float) -> void:
	if not _active:
		return
	while _ev_i < _events.size() and _frame >= int(_events[_ev_i].get("f", 0)):
		_run_event(_events[_ev_i])
		_ev_i += 1
	_apply_camera()
	_frame += 1
	if _frame >= _end_frame:
		_active = false
		print("TRAILER_SHOT_END=%s frames=%d" % [_shot, _frame])
		# Route through AppExit (the run-frames path) so Godot's movie-maker FINALIZES the file — a bare
		# get_tree().quit() with auto_accept_quit off leaves the recording unwritten.
		LAAppExit.request(self, 0)


## Interpolate the camera between the two surrounding keys (eased), aim it, using radial up so it stays level.
func _apply_camera() -> void:
	if _camera == null or _cam_keys.size() < 1 or _body == null:
		return
	var a: Dictionary = _cam_keys[0]
	var b: Dictionary = _cam_keys[_cam_keys.size() - 1]
	for i in range(_cam_keys.size() - 1):
		if _frame >= int(_cam_keys[i]["f"]) and _frame <= int(_cam_keys[i + 1]["f"]):
			a = _cam_keys[i]
			b = _cam_keys[i + 1]
			break
	var span: float = maxf(1.0, float(int(b["f"]) - int(a["f"])))
	var t: float = smoothstep(0.0, 1.0, clampf(float(_frame - int(a["f"])) / span, 0.0, 1.0))
	var pos: Vector3 = (a["pos"] as Vector3).lerp(b["pos"] as Vector3, t)
	var look: Vector3 = (a["look"] as Vector3).lerp(b["look"] as Vector3, t)
	_camera.global_position = pos
	var vdir: Vector3 = look - pos
	if vdir.length() < 0.001:
		return
	var up: Vector3 = (pos - _body.center()).normalized()
	if up.length() < 0.1 or absf(up.dot(vdir.normalized())) > 0.98:
		up = Vector3.UP
	_camera.look_at(look, up)


func _run_event(ev: Dictionary) -> void:
	var action: String = String(ev.get("do", ""))
	var arg = ev.get("arg", null)
	match action:
		"fast":
			if _input != null and _input.has_method("set_time_scale"):
				_input.set_time_scale(int(arg))
		"volcano":
			_tracked = _spawn_volcano(arg as Vector3)
		"lightning":
			if _disasters != null and _disasters.has_method("strike_random_lightning"):
				_disasters.strike_random_lightning()
		"meteor_from_left":
			_fling_meteor_from_left()
		_:
			push_warning("TrailerDirector: unknown event '%s'" % action)


func _spawn_volcano(point: Vector3) -> Node3D:
	if _disasters != null and _disasters.has_method("spawn_volcano"):
		var v = _disasters.spawn_volcano(point)
		return v if v is Node3D else null
	return null


## Fling a meteor in from the side of the frame OPPOSITE the sun (your brief: from behind-left, not the sun side).
func _fling_meteor_from_left() -> void:
	if _disasters == null or not _disasters.has_method("fire_meteor_at") or _camera == null or _body == null:
		# Fallback: the generic auto-meteor if the aimed API isn't present.
		if _disasters != null and _disasters.has_method("fire_test_meteor"):
			_disasters.fire_test_meteor()
		return
	var centre: Vector3 = _body.center()
	var r: float = _radius()
	var left: Vector3 = -_camera.global_transform.basis.x    # screen-left in world space
	var up: Vector3 = _camera.global_transform.basis.y
	var from_pos: Vector3 = centre + left * (r * 7.0) + up * (r * 2.0)
	_disasters.fire_meteor_at(centre + up * (r * 0.2), from_pos)


func _radius() -> float:
	return float(_body.radius()) if _body != null and _body.has_method("radius") else 200.0


## Build a shot's camera path + events from the live planet geometry (centre/radius), so framing is correct at
## any scale. Distances are in radius-multiples. Frames at 60 fps.
func _build_shot(shot: String) -> void:
	if _body == null:
		return
	var centre: Vector3 = _body.center()
	var r: float = _radius()
	# A lit-ish surface spot to erupt at + its radial up and a tangent to slide along.
	var edir: Vector3 = Vector3(0.55, 0.45, 0.70).normalized()
	var surf: Vector3 = centre + edir * r
	var up0: Vector3 = edir
	var tan: Vector3 = up0.cross(Vector3.UP)
	if tan.length() < 0.1:
		tan = up0.cross(Vector3.RIGHT)
	tan = tan.normalized()
	var wide_dir: Vector3 = (up0 * 0.75 + tan * 0.5).normalized()

	match shot:
		"chaos", "eruption", "reveal", "serenity":
			# CLOSE on the erupting surface (no planet visible) → back out through the chaos → whole planet + a
			# meteor sweeping in from the side opposite the sun. One continuous pull-back.
			_cam_keys = [
				{"f": 0,   "pos": surf + up0 * (r * 0.06) + tan * (r * 0.14), "look": surf + up0 * (r * 0.03)},
				{"f": 120, "pos": surf + up0 * (r * 0.10) + tan * (r * 0.20), "look": surf + up0 * (r * 0.04)},
				{"f": 300, "pos": surf + up0 * (r * 0.9)  + tan * (r * 0.6),  "look": surf},
				{"f": 460, "pos": centre + wide_dir * (r * 3.0),             "look": centre},
				{"f": 620, "pos": centre + wide_dir * (r * 4.2),             "look": centre},
			]
			_events = [
				{"f": 0,   "do": "fast", "arg": 3},              # brief warm-up presim
				{"f": 40,  "do": "volcano", "arg": surf},
				{"f": 60,  "do": "fast", "arg": 1},              # realtime for the action
				{"f": 90,  "do": "lightning"},
				{"f": 210, "do": "lightning"},
				{"f": 470, "do": "meteor_from_left"},
			]
		"life":
			# Low, slow pass over the living surface (you don't know it's a planet) — framed on the herds.
			var life: Vector3 = _herd_centroid(centre + Vector3(0.6, 0.5, 0.62).normalized() * r)
			var lup: Vector3 = (life - centre).normalized()
			var ltan: Vector3 = lup.cross(Vector3.UP)
			ltan = ltan.normalized() if ltan.length() > 0.1 else lup.cross(Vector3.RIGHT).normalized()
			_cam_keys = [
				{"f": 0,   "pos": life + lup * (r * 0.05) - ltan * (r * 0.18), "look": life + lup * (r * 0.02)},
				{"f": 240, "pos": life + lup * (r * 0.06) + ltan * (r * 0.18), "look": life + lup * (r * 0.02)},
			]
			_events = [{"f": 0, "do": "fast", "arg": 2}, {"f": 30, "do": "fast", "arg": 1}]
		_:
			_cam_keys = []


## Centroid of the nearest creature cluster to `near` (so the life shot frames where the animals actually are).
func _herd_centroid(near: Vector3) -> Vector3:
	if not is_inside_tree():
		return near
	var best: Vector3 = near
	var best_d: float = INF
	var sum: Vector3 = Vector3.ZERO
	var n: int = 0
	for c in get_tree().get_nodes_in_group("creature"):
		if c is Node3D:
			var d: float = (c as Node3D).global_position.distance_to(near)
			if d < best_d:
				best_d = d
				best = (c as Node3D).global_position
			if d < 60.0:
				sum += (c as Node3D).global_position
				n += 1
	return (sum / float(n)) if n > 0 else best


## Recursively hide every CanvasLayer so no game UI (HUD, debug panel, view-mode bar, thought panel) leaks in.
func _hide_all_ui() -> void:
	if is_inside_tree():
		_hide_canvas_layers(get_tree().root)

func _hide_canvas_layers(node: Node) -> void:
	for child in node.get_children():
		if child is CanvasLayer:
			(child as CanvasLayer).visible = false
		_hide_canvas_layers(child)
