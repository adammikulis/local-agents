@icon("res://addons/local_agents/icons/local_agent_harness.svg")
class_name LocalAgentDemoHarness
extends Node


const ARG_RUN_FRAMES: String = "--run-frames="
const ARG_SHOOT: String = "--shoot="
const ARG_SHOOT_FRAMES: String = "--shoot-frames="

@export_group("Headless run")
## Frames to run before printing the report and quitting. 0 = never auto-quit (normal interactive play).
## The command line overrides this: `-- --run-frames=N`.
@export_range(0, 100000, 1, "suffix:frames") var run_frames: int = 0

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
@export_global_file("*.png") var shoot_path: String = ""
## Frame the screenshot is taken on. Give the scene enough frames to settle before it shoots.
## The command line overrides this: `-- --shoot-frames=N`.
@export_range(1, 100000, 1, "suffix:frames") var shoot_frames: int = 90

@export_group("Exit")
## Route the quit through the LAAppExit autoload when it is registered (game installs), otherwise
## `get_tree().quit()`. Keeps the addon usable in projects that do not register that autoload.
@export var use_app_exit: bool = true

var _frame: int = 0          # run length, in PHYSICS ticks. A simulation is not measured on render frames.
var _render_frame: int = 0   # render frames only; drives shoot_frames
var _done: bool = false


func _ready() -> void:
	_parse_cli()
	if report_source == null:
		report_source = get_parent()
	if report_source != null and report_source.has_method("demo_harness_configured"):
		report_source.call("demo_harness_configured", run_frames, shoot_path)
	# Nothing to count when neither mode is armed — stay off the per-frame paths entirely.
	set_process(shoot_path != "")
	set_physics_process(run_frames > 0)


## Run-length frames counted so far. Equals `run_frames` at the moment the report is emitted.
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
	if not _done and shoot_path != "" and _render_frame >= shoot_frames:
		_done = true
		_capture(shoot_path)
		_quit(0)
		return


func _tick_run() -> void:
	if _done:
		return
	_frame += 1
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


func _capture(path: String) -> void:
	var viewport: Viewport = get_viewport()
	if viewport == null:
		return
	var img: Image = viewport.get_texture().get_image()
	img.save_png(path)
	var extra: String = ""
	if report_source != null and report_source.has_method("demo_shot_info"):
		var info: String = String(report_source.call("demo_shot_info"))
		if info != "":
			extra = " " + info
	print("SHOT_SAVED=%s size=%dx%d%s" % [path, img.get_width(), img.get_height(), extra])


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
