@icon("res://addons/local_agents/icons/local_agent_harness.svg")
class_name LocalAgentDemoHarness
extends Node


const ARG_RUN_FRAMES: String = "--run-frames="
const ARG_SHOOT: String = "--shoot="
const ARG_SHOOT_FRAMES: String = "--shoot-frames="
const ARG_SHOOT_SIZE: String = "--shoot-size="
const ARG_SHOOT_STEP: String = "--shoot-step="
const ARG_SHOTS: String = "--shots="
const ARG_SHOT_WITHOUT: String = "--shot-without="
const DEFAULT_SHOOT_SIZE: Vector2i = Vector2i(1280, 800)

@export_group("Headless run")
## Frames to run before printing the report and quitting. 0 = never auto-quit (normal interactive play).
## The command line overrides this: `-- --run-frames=N`.
@export_range(0, 100000, 1, "suffix:frames") var run_frames: int = 0:
	set(value):
		run_frames = value
		_arm()

## Node queried for the report payload. It must expose `demo_report() -> Dictionary`.
## Left empty, the parent node is used, so dropping this harness under a scene root just works.
@export var report_source: Node
## Marker prefix for the printed line, e.g. "BOX_FIELD" prints `BOX_FIELD_REPORT={...}`.
## Nothing in scripts/ or CI greps these today. Keep it stable anyway so saved logs stay comparable.
@export var report_prefix: String = "DEMO"
## Text joined onto the prefix to form the marker. The default gives `PREFIX_REPORT={...}`.
## Clear it to print a bare `PREFIX={...}`.
@export var report_suffix: String = "_REPORT"

@export_group("Screenshot")
@export_global_file("*.png") var shoot_path: String = "":
	set(value):
		shoot_path = value
		_arm()
## Frame the screenshot is taken on. Give the scene enough frames to settle before it shoots.
## The command line overrides this: `-- --shoot-frames=N`.
@export_range(1, 100000, 1, "suffix:frames") var shoot_frames: int = 90
## Simulated step every picture is of: the loop halts there and the shot waits for it. -1 shoots whatever
## step the frame lands on. The command line overrides this: `-- --shoot-step=N`.
@export_range(-1, 100000, 1, "suffix:steps") var shoot_step: int = -1

@export_group("Exit")
## Route the quit through the AppExit autoload when it is registered (game installs), otherwise
## `get_tree().quit()`. Keeps the addon usable in projects that do not register that autoload.
@export var use_app_exit: bool = true

var _frame: int = 0          # run length, in SIM STEPS when a LASimLoop is running; physics ticks otherwise.
var _render_frame: int = 0   # render frames only; drives shoot_frames
var _shot_timed_out: bool = false
var _ready_frames: int = 0   # consecutive frames the host has called the picture worth taking
var _done: bool = false

# --shots: camera poses photographed in turn, all in ONE launch. Empty = the single --shoot picture.
var _shots_spec: String = ""
var _poses: Array[Vector3] = []       # alt_m, pitch_deg, yaw_deg
var _pose_index: int = 0
var _pose_applied: int = -1
var _pose_deadline_ms: int = 0
# --shot-without: each pose photographed again with each named LAAblate module switched off.
var _without: PackedStringArray = PackedStringArray()
var _without_at: int = -1             # the module this pose is being photographed without; -1 = none
var _hold: int = 0                    # frames left before a switched-off module is out of the picture

# The image read out is the one drawn BEFORE this frame, so readiness must have held through that draw.
const SHOT_SETTLE_FRAMES: int = 2
# A host that can say whether the picture is worth taking is waited on in WALL TIME, up to the run's own
# ceiling less this margin, then shot anyway; the shot says what state it was in. Meshing is thread work.
const SHOT_WAIT_MARGIN_S: float = 10.0


func _ready() -> void:
	_parse_cli()
	if report_source == null:
		report_source = get_parent()
	if report_source != null and report_source.has_method("demo_harness_configured"):
		report_source.call("demo_harness_configured", run_frames, shoot_path)
	_pose_deadline_ms = _shot_deadline_ms()
	_check_shots()
	_arm()


## A --shots run this scene cannot honour is a failed run, never one silent picture from the old pose.
func _check_shots() -> void:
	if _shots_spec == "":
		return
	if _poses.is_empty():
		_done = true
		print("SHOT_SPEC_INVALID=%s" % _shots_spec)
		_quit(2)
	elif report_source == null or not report_source.has_method("demo_shot_pose"):
		_done = true
		print("SHOT_POSE_UNSUPPORTED=%s" % _shots_spec)
		_quit(2)


## Nothing to count when neither mode is armed: stay off the per-frame paths entirely. Armed on every
## write, not only in _ready(), so a host that sets run_frames after add_child() still gets counted.
func _arm() -> void:
	if not is_inside_tree():
		return
	set_process(shoot_path != "")
	set_physics_process(run_frames > 0)


## Run-length steps counted so far. Equals `run_frames` at the moment the report is emitted.
func frames_elapsed() -> int:
	return _frame


## Render frames counted so far. The clock `shoot_frames` is measured on.
func render_frames_elapsed() -> int:
	return _render_frame


func _physics_process(_delta: float) -> void:
	_tick_run()


func _process(_delta: float) -> void:
	_render_frame += 1
	# Screenshot first: a scene given both flags is being photographed, not measured.
	if _done or shoot_path == "" or not _at_shoot_step() or _render_frame < shoot_frames:
		return
	if _poses.is_empty():
		if not _settled():
			return
		_done = true
		_capture(shoot_path)
		_quit(2 if _shot_timed_out else 0)
		return
	# ONE LAUNCH, MANY PICTURES: move to the pose, let the ground arrive under it, photograph, next.
	if _pose_applied != _pose_index:
		report_source.call("demo_shot_pose", _poses[_pose_index].x, _poses[_pose_index].y,
			_poses[_pose_index].z)
		_pose_applied = _pose_index
		_ready_frames = 0
		_pose_deadline_ms = _pose_budget_ms(_pose_index)
		return
	if _without_at >= 0:
		_photograph_without()
		return
	if not _settled():
		return
	var pose: Vector3 = _poses[_pose_index]
	_capture(pose_path(shoot_path, _pose_index, pose),
		" shot_index=%d shot_pose=%s" % [_pose_index, pose_tag(pose)])
	_ready_frames = 0
	if _shot_timed_out or _without.is_empty():
		_next_pose()
		return
	_without_at = 0
	_switch_without(false)


## The same pose again once the module is out of the picture, then the next module or the next pose.
func _photograph_without() -> void:
	if _hold > 0:
		_hold -= 1
		return
	var pose: Vector3 = _poses[_pose_index]
	var module: String = _without[_without_at]
	_capture(without_path(pose_path(shoot_path, _pose_index, pose), module),
		" shot_index=%d shot_pose=%s shot_without=%s" % [_pose_index, pose_tag(pose), module])
	_switch_without(true)
	_without_at += 1
	if _without_at < _without.size():
		_switch_without(false)
		return
	_without_at = -1
	_next_pose()


## A name LAAblate does not hold would photograph the pose unchanged under a label saying otherwise.
func _switch_without(on: bool) -> void:
	var module: String = _without[_without_at]
	if LAAblate.kind_of(module) == "":
		_done = true
		print("SHOT_WITHOUT_UNKNOWN=%s" % module)
		_quit(2)
		return
	LAAblate.set_on(module, on)
	_hold = SHOT_SETTLE_FRAMES


func _next_pose() -> void:
	if _shot_timed_out:
		_done = true
		_quit(2)
		return
	_pose_index += 1
	if _pose_index >= _poses.size():
		_done = true
		_quit(0)


## The loop stands at `shoot_step`, halted there from the first frame. True with no step declared. A loop
## already past it cannot be photographed at it, and the run fails.
func _at_shoot_step() -> bool:
	if shoot_step < 0:
		return true
	var loop: LASimLoop = LASimLoop.active()
	if loop == null:
		return false
	loop.halt_at(shoot_step)
	if loop.step_index() > shoot_step:
		_done = true
		print("SHOT_STEP_PASSED=%d" % loop.step_index())
		_quit(2)
	return loop.step_index() == shoot_step


## Ready for SHOT_SETTLE_FRAMES running, or out of the time this pose was given.
func _settled() -> bool:
	if not _has_shot_ready_hook():
		return true
	_ready_frames = _ready_frames + 1 if bool(report_source.call("demo_shot_ready")) else 0
	if _ready_frames >= SHOT_SETTLE_FRAMES:
		return true
	_shot_timed_out = Time.get_ticks_msec() >= _pose_deadline_ms
	return _shot_timed_out


## The first pose waits for startup; subsequent poses share the remaining run time.
func _pose_budget_ms(index: int) -> int:
	if index == 0:
		return _shot_deadline_ms()
	var now: int = Time.get_ticks_msec()
	var left: int = maxi(_shot_deadline_ms() - now, 1)
	return now + int(float(left) / float(maxi(_poses.size() - index, 1)))


## `alt:pitch:yaw` as the pose was asked for, so a saved line can be read back against the request.
static func pose_tag(pose: Vector3) -> String:
	return "%d:%d:%d" % [roundi(pose.x), roundi(pose.y), roundi(pose.z)]


static func pose_path(base: String, index: int, pose: Vector3) -> String:
	var stem: String = base.get_basename()
	return "%s_%d_%dm_%d_%d.%s" % [stem, index, roundi(pose.x), roundi(pose.y), roundi(pose.z),
		base.get_extension()]


static func without_path(pose_png: String, module: String) -> String:
	return "%s_without_%s.%s" % [pose_png.get_basename(), module, pose_png.get_extension()]


## `alt_m:pitch_deg:yaw_deg` triples separated by `;`. Empty when any of them is malformed: a pose the
## run cannot honour is not silently dropped from the protocol.
static func parse_shots(spec: String) -> Array[Vector3]:
	var out: Array[Vector3] = []
	for chunk in spec.split(";", false):
		var f: PackedStringArray = String(chunk).strip_edges().split(":")
		if f.size() != 3 or not (f[0].is_valid_float() and f[1].is_valid_float() and f[2].is_valid_float()):
			push_error("--shots: '%s' is not alt_m:pitch_deg:yaw_deg" % chunk)
			return []
		out.append(Vector3(float(f[0]), float(f[1]), float(f[2])))
	return out


## A host that can say whether the picture is worth taking (e.g. the ground under its camera is drawn at
## the detail the camera stands at) is waited on past `shoot_frames`; one that cannot is shot on the frame.
## The run's ceiling (LA_RUN_TIMEOUT, the launcher's kill), less the margin the capture and quit need.
func _shot_deadline_ms() -> int:
	var ceiling_s: float = 60.0
	if OS.has_environment("LA_RUN_TIMEOUT"):
		ceiling_s = float(OS.get_environment("LA_RUN_TIMEOUT"))
	return int(maxf(ceiling_s - SHOT_WAIT_MARGIN_S, 1.0) * 1000.0)


func _has_shot_ready_hook() -> bool:
	return report_source != null and report_source.has_method("demo_shot_ready")


## A scene carrying a LASimLoop is measured on ITS clock: the run is N simulated steps, and a slow frame
## does not shorten it. A demo scene with no simulation has only the engine's physics tick.
func _tick_run() -> void:
	if _done:
		return
	var loop: LASimLoop = LASimLoop.active()
	if loop != null and loop.failure != "":
		_done = true
		emit_report()
		print("RUN_FAILED=" + JSON.stringify({"step": loop.step_index(), "reason": loop.failure}))
		_quit(EXIT_RUN_FAILED)
		return
	_frame = loop.step_index() if loop != null else _frame + 1
	if run_frames > 0 and _frame >= run_frames:
		_done = true
		emit_report()
		_quit(_exit_code())


const COMPLETE_MARKER: String = "LA_RUN_COMPLETE"
## The exit of a run whose loop stopped on a step that could not complete.
const EXIT_RUN_FAILED: int = 1


## Print the report line now, without quitting. Public so a host can force a report at any moment.
func emit_report() -> void:
	print("%s%s=%s" % [report_prefix, report_suffix, _report_body()])


static func print_complete(code: int) -> void:
	print("%s={\"code\":%d}" % [COMPLETE_MARKER, code])


func _report_body() -> String:
	if report_source == null:
		return "{}"
	if report_source.has_method("demo_report_json"):
		return String(report_source.call("demo_report_json"))
	if report_source.has_method("demo_report"):
		var payload: Dictionary = report_source.call("demo_report")
		# sort_keys=false: the fields print in the order the source declared them, so a report stays
		# readable (frames first, then the measurements) instead of alphabetised.
		return JSON.stringify(payload, "", false)
	return "{}"


func _exit_code() -> int:
	if report_source != null and report_source.has_method("demo_exit_code"):
		return int(report_source.call("demo_exit_code"))
	return 0


## The one viewport-to-PNG path. Every screenshot in the project goes through it.
static func save_viewport_png(viewport: Viewport, path: String, extra: String = "") -> void:
	if viewport == null:
		return
	# THE WINDOW IS NOT THE PICTURE. A shot read off a SubViewport leaves the window at its automated
	# one pixel, and this is the reading that says so.
	print(LAQuietWindow.state_line())
	var img: Image = viewport.get_texture().get_image()
	img.save_png(path)
	print("SHOT_SAVED=%s size=%dx%d%s" % [path, img.get_width(), img.get_height(), extra])


func _capture(path: String, pose_tag_text: String = "") -> void:
	var extra: String = pose_tag_text
	if report_source != null and report_source.has_method("demo_shot_info"):
		var info: String = String(report_source.call("demo_shot_info"))
		if info != "":
			extra += " " + info
	save_viewport_png(shot_viewport(), path, extra)


## The surface this harness photographs. A host drawing into an off-screen SubViewport names it.
func shot_viewport() -> Viewport:
	if report_source != null and report_source.has_method("shot_viewport"):
		return report_source.call("shot_viewport") as Viewport
	return get_viewport()


func _quit(code: int) -> void:
	var tree: SceneTree = get_tree()
	if tree == null:
		return
	print_complete(code)
	if use_app_exit:
		LAAppQuit.request(self, code)
		return
	tree.quit(code)


## The off-screen surface a scene is photographed on, sized by --shoot-size. The OS window stays at the
## one pixel LAQuietWindow gives it, so no screenshot needs a window that can land on a monitor.
static func offscreen_shot_viewport(scene: Node) -> SubViewport:
	var vp: SubViewport = SubViewport.new()
	vp.name = "ShotViewport"
	vp.size = parse_shoot_size()
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	scene.get_tree().root.add_child(vp)
	scene.reparent(vp)
	return vp


static func parse_shoot_size(fallback: Vector2i = DEFAULT_SHOOT_SIZE) -> Vector2i:
	for arg_v in OS.get_cmdline_user_args():
		var arg: String = String(arg_v)
		if arg.begins_with(ARG_SHOOT_SIZE):
			var wh: PackedStringArray = arg.substr(ARG_SHOOT_SIZE.length()).split("x")
			if wh.size() == 2:
				return Vector2i(maxi(1, int(wh[0])), maxi(1, int(wh[1])))
	return fallback


static func parse_run_frames(fallback: int = 0) -> int:
	for arg_v in OS.get_cmdline_user_args():
		var arg: String = String(arg_v)
		if arg.begins_with(ARG_RUN_FRAMES):
			return maxi(0, int(arg.substr(ARG_RUN_FRAMES.length())))
	return fallback


func _parse_cli() -> void:
	run_frames = parse_run_frames(run_frames)
	Engine.set_meta("la_run_frames", run_frames)
	for arg_v in OS.get_cmdline_user_args():
		var arg: String = String(arg_v)
		if arg.begins_with(ARG_SHOOT_FRAMES):
			shoot_frames = maxi(1, int(arg.substr(ARG_SHOOT_FRAMES.length())))
		elif arg.begins_with(ARG_SHOOT_STEP):
			shoot_step = maxi(0, int(arg.substr(ARG_SHOOT_STEP.length())))
		elif arg.begins_with(ARG_SHOTS):
			_shots_spec = arg.substr(ARG_SHOTS.length())
			_poses = parse_shots(_shots_spec)
		elif arg.begins_with(ARG_SHOT_WITHOUT):
			_without = arg.substr(ARG_SHOT_WITHOUT.length()).split(",", false)
		elif arg.begins_with(ARG_SHOOT):
			shoot_path = arg.substr(ARG_SHOOT.length())
