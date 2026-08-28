@icon("res://addons/local_agents/icons/local_agent_harness.svg")
class_name LocalAgentDemoHarness
extends Node


const ARG_RUN_FRAMES: String = "--run-frames="
const ARG_SHOOT: String = "--shoot="
const ARG_SHOOT_FRAMES: String = "--shoot-frames="
const ARG_SHOOT_SIZE: String = "--shoot-size="
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

@export_group("Exit")
## Route the quit through the LAAppExit autoload when it is registered (game installs), otherwise
## `get_tree().quit()`. Keeps the addon usable in projects that do not register that autoload.
@export var use_app_exit: bool = true

var _frame: int = 0          # run length, in SIM STEPS when a LASimLoop is running; physics ticks otherwise.
var _render_frame: int = 0   # render frames only; drives shoot_frames
var _ready_frames: int = 0   # consecutive frames the host has called the picture worth taking
var _done: bool = false

# The image read out is the one drawn BEFORE this frame, so readiness must have held through that draw.
const SHOT_SETTLE_FRAMES: int = 2
# A host that can say whether the picture is worth taking gets as long again to say so, then is shot anyway
# and the shot says what state it was in.
const SHOT_WAIT_MULT: int = 2


func _ready() -> void:
	_parse_cli()
	if report_source == null:
		report_source = get_parent()
	if report_source != null and report_source.has_method("demo_harness_configured"):
		report_source.call("demo_harness_configured", run_frames, shoot_path)
	_arm()


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
	if _done or shoot_path == "" or _render_frame < shoot_frames:
		return
	if _has_shot_ready_hook():
		_ready_frames = _ready_frames + 1 if bool(report_source.call("demo_shot_ready")) else 0
		if _ready_frames < SHOT_SETTLE_FRAMES and _render_frame < shoot_frames * SHOT_WAIT_MULT:
			return
	_done = true
	_capture(shoot_path)
	_quit(0)


## A host that can say whether the picture is worth taking (e.g. the ground under its camera is drawn at
## the detail the camera stands at) is waited on past `shoot_frames`; one that cannot is shot on the frame.
func _has_shot_ready_hook() -> bool:
	return report_source != null and report_source.has_method("demo_shot_ready")


## A scene carrying a LASimLoop is measured on ITS clock: the run is N simulated steps, and a slow frame
## does not shorten it. A demo scene with no simulation has only the engine's physics tick.
func _tick_run() -> void:
	if _done:
		return
	var loop: LASimLoop = LASimLoop.active()
	_frame = loop.step_index() if loop != null else _frame + 1
	if run_frames > 0 and _frame >= run_frames:
		_done = true
		emit_report()
		_quit(_exit_code())


const COMPLETE_MARKER: String = "LA_RUN_COMPLETE"


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
	print(_structure_line(img))


func _capture(path: String) -> void:
	var extra: String = ""
	if report_source != null and report_source.has_method("demo_shot_info"):
		var info: String = String(report_source.call("demo_shot_info"))
		if info != "":
			extra = " " + info
	save_viewport_png(shot_viewport(), path, extra)


## The surface this harness photographs. A host drawing into an off-screen SubViewport names it.
func shot_viewport() -> Viewport:
	if report_source != null and report_source.has_method("shot_viewport"):
		return report_source.call("shot_viewport") as Viewport
	return get_viewport()


## WHAT EACH HALF OF THE PICTURE LOOKS LIKE. A sky is a vertical gradient: constant along a row, so its
## row variance is ~0, and a frame that is sky top and bottom has two halves of the same brightness.
## Ground in the lower half breaks both. scripts/check_ground_drawn.sh reads this line.
const STRUCTURE_SAMPLES: int = 64

static func _structure_line(img: Image) -> String:
	var up: Vector2 = _half_stats(img, 0)
	var low: Vector2 = _half_stats(img, 1)
	return 'SHOT_STRUCTURE={"upper":%.6f,"lower":%.6f,"upper_mean":%.6f,"lower_mean":%.6f}' % [
		up.y, low.y, up.x, low.x]


## Mean luminance (x) and mean per-row variance along x (y) over one half of the image.
static func _half_stats(img: Image, half: int) -> Vector2:
	var w: int = img.get_width()
	var h: int = img.get_height()
	if w < 2 or h < 2:
		return Vector2.ZERO
	var y0: int = (h / 2) * half
	var var_total: float = 0.0
	var mean_total: float = 0.0
	for j in range(STRUCTURE_SAMPLES):
		var y: int = y0 + (h / 2) * j / STRUCTURE_SAMPLES
		var sum: float = 0.0
		var sq: float = 0.0
		for i in range(STRUCTURE_SAMPLES):
			# The middle half only: HUD panels hug the edges and would stand in for scenery.
			var v: float = img.get_pixel(w / 4 + (w / 2) * i / STRUCTURE_SAMPLES, mini(y, h - 1)).get_luminance()
			sum += v
			sq += v * v
		var n: float = float(STRUCTURE_SAMPLES)
		mean_total += sum / n
		var_total += maxf(0.0, sq / n - (sum / n) * (sum / n))
	var rows: float = float(STRUCTURE_SAMPLES)
	return Vector2(mean_total / rows, var_total / rows)


func _quit(code: int) -> void:
	var tree: SceneTree = get_tree()
	if tree == null:
		return
	print_complete(code)
	if use_app_exit:
		var app_exit: Node = tree.root.get_node_or_null("AppExit")
		if app_exit != null and app_exit.has_method("quit"):
			app_exit.call("quit", code)
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
		elif arg.begins_with(ARG_SHOOT):
			shoot_path = arg.substr(ARG_SHOOT.length())
