class_name LATrailerDirector
extends Node

## SCENE SCRIPTER for capturing trailer/marketing shots deterministically (docs/TRAILER.md). One shot per run:
##   godot --write-movie=<out.avi> ... -- --trailer-shot=<name> [--fast=N]
## (or via scripts/capture_trailer.sh, which pins the seed + drives Godot's movie-maker.)
##
## A shot is a data timeline of BEATS — {at: <frame>, do: <action>, arg: <value>} — fired in order while the
## camera + events play out; the run auto-quits when the shot ends. Because Godot's movie-maker records every
## rendered frame at a FIXED timestep, a `fast N` beat (N sim steps / frame) becomes a time-lapse in the footage
## AND is how you "line up shots" — presimulate the world to a state (grown forest, big herd, hot volcano) fast,
## then drop to realtime for the action. Shots are independent — capture each in its own run and cut together.
## The director takes over the camera + hides the HUD so the footage is clean. (Explicit types; no ':='.)

var _world: Node = null
var _camera: Camera3D = null          # LAVoxelCameraRig (is a Camera3D)
var _disasters: Node = null
var _input: Node = null
var _body: Node = null                # LAPlanetBody
var _hud_root: CanvasLayer = null

var _shot: String = ""
var _frame: int = 0
var _beats: Array = []                # [{at:int, do:String, arg}]
var _beat_i: int = 0
var _end_frame: int = 0
var _active: bool = false
var _tracked: Node3D = null           # a spawned actor the camera follows (volcano/meteor)


## Called by VoxelWorld when `--trailer-shot=<name>` was parsed. Wires refs + selects the shot timeline.
func begin(world: Node, camera: Camera3D, disasters: Node, input: Node, body: Node, hud_root: CanvasLayer, shot: String) -> void:
	_world = world
	_camera = camera
	_disasters = disasters
	_input = input
	_body = body
	_hud_root = hud_root
	_shot = shot
	_beats = _shot_beats(shot)
	if _beats.is_empty():
		push_warning("TrailerDirector: unknown shot '%s'" % shot)
		return
	_end_frame = int(_beats.back().get("at", 0)) + int(_beats.back().get("hold", 120))
	# Clean footage: hide the HUD overlay and stop the camera driving itself from input.
	if _hud_root != null:
		_hud_root.visible = false
	if _input != null and _input.has_method("set_capture_mode"):
		_input.set_capture_mode(true)
	_active = true
	print("TRAILER_SHOT_BEGIN=%s end_frame=%d" % [shot, _end_frame])


func _process(_delta: float) -> void:
	if not _active:
		return
	# Fire every beat whose frame has arrived.
	while _beat_i < _beats.size() and _frame >= int(_beats[_beat_i].get("at", 0)):
		_run_beat(_beats[_beat_i])
		_beat_i += 1
	# Keep following a tracked actor (volcano/meteor) if the shot asked for it.
	if _tracked != null and is_instance_valid(_tracked) and _camera != null and _camera.has_method("track_target"):
		_camera.track_target(_tracked)
	_frame += 1
	if _frame >= _end_frame:
		_active = false
		print("TRAILER_SHOT_END=%s frames=%d" % [_shot, _frame])
		get_tree().quit()


## Run one beat. Actions map onto the existing camera-rig / disaster / input / world APIs — no bespoke systems.
func _run_beat(beat: Dictionary) -> void:
	var action: String = String(beat.get("do", ""))
	var arg = beat.get("arg", null)
	match action:
		"fast":
			if _input != null and _input.has_method("set_time_scale"):
				_input.set_time_scale(int(arg))
		"cam_orbit":
			if _input != null and _input.has_method("set_orbit_mode"):
				_input.set_orbit_mode()
		"cam_fly":
			if _input != null and _input.has_method("set_fly"):
				_input.set_fly(true)
		"cam_geosync":
			if _input != null and _input.has_method("set_geosync"):
				_input.set_geosync(true)
		"cam_solar":
			if _input != null and _input.has_method("set_solar_view"):
				_input.set_solar_view(true)
		"cam_overview":
			if _camera != null and _camera.has_method("frame_overview") and _body != null:
				_camera.frame_overview(_body.center(), float(arg))
		"cam_vista":
			if _camera != null and _camera.has_method("frame_vista") and _body != null:
				_camera.frame_vista(_body.center())
		"cam_distance":
			# Ease the orbit distance toward arg over the coming frames (a dolly in/out) via frame_overview.
			if _camera != null and _camera.has_method("frame_overview") and _body != null:
				_camera.frame_overview(_body.center(), float(arg))
		"volcano":
			_tracked = _spawn_disaster_on_surface("volcano")
		"meteor":
			if _disasters != null and _disasters.has_method("fire_test_meteor"):
				_disasters.fire_test_meteor()
		"lightning":
			if _disasters != null and _disasters.has_method("strike_random_lightning"):
				_disasters.strike_random_lightning()
		"track_none":
			_tracked = null
		_:
			push_warning("TrailerDirector: unknown beat action '%s'" % action)


## Spawn a disaster at a surface point facing the camera (so it's in frame). Returns the actor to track.
func _spawn_disaster_on_surface(kind: String) -> Node3D:
	if _disasters == null or _body == null:
		return null
	# A point on the sunlit side of the planet's surface (deterministic).
	var dir: Vector3 = Vector3(0.6, 0.5, 0.62).normalized()
	var point: Vector3 = _body.center() + dir * (float(_body.radius()) if _body.has_method("radius") else 200.0)
	if kind == "volcano" and _disasters.has_method("spawn_volcano"):
		var v = _disasters.spawn_volcano(point)
		return v if v is Node3D else null
	return null


## The shot timelines (docs/TRAILER.md). Frames at 60 fps; movie-maker fps is set on the Godot command line.
## Each beat: {at: frame, do: action, arg: value, hold: tail-frames (last beat only)}.
func _shot_beats(shot: String) -> Array:
	match shot:
		"serenity":
			# Low vista over the living surface; a gentle fast intro grows the scene in, then realtime.
			return [
				{"at": 0, "do": "cam_vista"},
				{"at": 0, "do": "fast", "arg": 6},
				{"at": 90, "do": "fast", "arg": 1},
				{"at": 90, "do": "cam_geosync"},
				{"at": 240, "do": "track_none", "hold": 60},
			]
		"eruption":
			# Presim the world hot + grown, then erupt a volcano and pull the fly-cam back through the chaos.
			return [
				{"at": 0, "do": "fast", "arg": 8},
				{"at": 120, "do": "fast", "arg": 1},
				{"at": 120, "do": "volcano"},
				{"at": 150, "do": "lightning"},
				{"at": 300, "do": "cam_overview", "arg": 320.0},
				{"at": 420, "do": "cam_overview", "arg": 620.0, "hold": 120},
			]
		"reveal":
			# Pull way back to the turning planet, snap to the solar-system view, then a meteor sweeps in.
			return [
				{"at": 0, "do": "cam_overview", "arg": 360.0},
				{"at": 0, "do": "fast", "arg": 4},
				{"at": 120, "do": "cam_overview", "arg": 900.0},
				{"at": 240, "do": "cam_solar"},
				{"at": 300, "do": "meteor"},
				{"at": 360, "do": "fast", "arg": 1, "hold": 150},
			]
		_:
			return []
