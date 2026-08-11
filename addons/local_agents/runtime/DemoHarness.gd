@icon("res://addons/local_agents/icons/local_agent_harness.svg")
class_name LocalAgentDemoHarness
extends Node

## The one headless run / report / screenshot harness for a demo scene.
##
## Drop it under any scene root, point `report_source` at the node that knows the numbers, and that
## scene gains the repo's standard command-line contract for free:
##
##     godot --headless --path . <scene>.tscn -- --run-frames=120
##     godot --path . <scene>.tscn -- --shoot=shot.png --shoot-frames=90
##
## Two clocks, because there are two questions. `run_frames` ends the run and is a SIMULATION horizon:
## with `count_physics_frames` it counts physics ticks, whose delta is fixed, so N is always the same
## simulated time on any machine. `shoot_frames` fires the screenshot and always counts render frames,
## because a screenshot's subject is the drawn image.
##
## The exit path resolves at run time, so it behaves the same with or without the game's `AppExit`
## autoload (a library-only install is told not to register it).
##
## The report source only ever answers questions. It never reads the command line itself.
##
## - `demo_report() -> Dictionary` is the payload, printed as JSON. This is the normal case.
## - `demo_report_json() -> String` is optional. The payload already serialised, for when exact number
##   formatting matters more than JSON conventions (e.g. two fixed decimals). Wins when present.
## - `demo_exit_code() -> int` is optional. Process exit code, default 0, so a smoke scene can fail.
## - `demo_shot_info() -> String` is optional. Extra `key=value` text appended to the SHOT_SAVED line.
## - `demo_harness_configured(frames: int, shoot: String) -> void` is optional. Called once, right
##   after the command line is parsed, so the scene can react to the resolved settings (auto-drive
##   itself, size a report) without re-reading argv.
##
## (Explicit types only. Project rule: no ':=' inferred typing.)

const ARG_RUN_FRAMES: String = "--run-frames="
const ARG_SHOOT: String = "--shoot="
const ARG_SHOOT_FRAMES: String = "--shoot-frames="

@export_group("Headless run")
## Frames to run before printing the report and quitting. 0 = never auto-quit (normal interactive play).
## The command line overrides this: `-- --run-frames=N`.
@export_range(0, 100000, 1, "suffix:frames") var run_frames: int = 0
## Count physics ticks instead of render frames for `run_frames`.
##
## A physics tick carries a fixed delta, so N ticks is always the same simulated time. A render frame
## does not, so N render frames is a machine-dependent amount of simulation. On for anything measuring
## a simulation; off for UI demos, where "frames" means frames drawn.
##
## `shoot_frames` is unaffected — a screenshot's subject is the drawn frame, so it always counts those.
@export var count_physics_frames: bool = false

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
## Save a PNG of the viewport at `shoot_frames`, print `SHOT_SAVED=...`, then quit. Empty = no screenshot.
## The command line overrides this: `-- --shoot=<path.png>`.
## Global, not @export_file: this is an output path, usually absolute or user://. res:// is read-only
## in an exported build, and a res://-rooted picker cannot express a valid value.
@export_global_file("*.png") var shoot_path: String = ""
## Frame the screenshot is taken on. Give the scene enough frames to settle before it shoots.
## The command line overrides this: `-- --shoot-frames=N`.
@export_range(1, 100000, 1, "suffix:frames") var shoot_frames: int = 90

@export_group("Exit")
## Route the quit through the LAAppExit autoload when it is registered (game installs), otherwise
## `get_tree().quit()`. Keeps the addon usable in projects that do not register that autoload.
@export var use_app_exit: bool = true

var _frame: int = 0          # run-length counter: physics ticks when count_physics_frames, else render frames
var _render_frame: int = 0   # render frames only; drives shoot_frames
var _done: bool = false


func _ready() -> void:
	_parse_cli()
	if report_source == null:
		report_source = get_parent()
	if report_source != null and report_source.has_method("demo_harness_configured"):
		report_source.call("demo_harness_configured", run_frames, shoot_path)
	# Nothing to count when neither mode is armed — stay off the per-frame paths entirely.
	set_process(shoot_path != "" or (run_frames > 0 and not count_physics_frames))
	set_physics_process(run_frames > 0 and count_physics_frames)


## Run-length frames counted so far. Equals `run_frames` at the moment the report is emitted.
func frames_elapsed() -> int:
	return _frame


## Render frames counted so far. The clock `shoot_frames` is measured on.
func render_frames_elapsed() -> int:
	return _render_frame


func _physics_process(_delta: float) -> void:
	if count_physics_frames:
		_tick_run()


func _process(_delta: float) -> void:
	_render_frame += 1
	# Screenshot first: a scene given both flags is being photographed, not measured.
	if not _done and shoot_path != "" and _render_frame >= shoot_frames:
		_done = true
		_capture(shoot_path)
		_quit(0)
		return
	if not count_physics_frames:
		_tick_run()


func _tick_run() -> void:
	if _done:
		return
	_frame += 1
	if run_frames > 0 and _frame >= run_frames:
		_done = true
		emit_report()
		_quit(_exit_code())


## The one line that means "this run is ending, deliberately". Printed immediately before the quit by
## every harness in the repo, and by nothing else.
##
## An external watchdog cannot reliably infer completion from the report line. run_sim_offscreen.sh
## tried, matching "an all-caps token followed by ={quote}" on the theory that only a JSON report body
## has quoted keys, and VoxelWorld's own periodic `POP_TRACE={"frame":180,...}` matches that exactly.
## The watchdog therefore armed at frame 180 and SIGKILLed healthy 800- and 1200-frame runs. An
## explicit sentinel is not a heuristic and no progress line can spoof it.
const COMPLETE_MARKER: String = "LA_RUN_COMPLETE"


## Print the report line now, without quitting. Public so a host can force a report at any moment.
func emit_report() -> void:
	print("%s%s=%s" % [report_prefix, report_suffix, _report_body()])


## Announce a deliberate end-of-run, with the exit code that is about to be used. Static so the voxel
## game's own harness can emit the identical marker without owning one of these nodes.
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


# The game registers an `AppExit` autoload that hard-exits around a MoltenVK teardown crash; a library
# consumer is explicitly told not to. So it is resolved BY NAME at runtime — never as a compile-time
# `LAAppExit.` reference, which is precisely the unresolved-identifier parse error this node removes.
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


## The one place `--run-frames=N` is read. Returns `fallback` when the flag is absent.
##
## Static and public because LAVoxelInputController needs the same number to place its own auto-demo
## schedule relative to the end of the run. It calls this rather than re-parsing the flag, so one
## spelling cannot become two.
static func parse_run_frames(fallback: int = 0) -> int:
	for arg_v in OS.get_cmdline_user_args():
		var arg: String = String(arg_v)
		if arg.begins_with(ARG_RUN_FRAMES):
			return maxi(0, int(arg.substr(ARG_RUN_FRAMES.length())))
	return fallback


func _parse_cli() -> void:
	run_frames = parse_run_frames(run_frames)
	# Published so the O(cells) report gauges can force one fresh recompute on the closing frame instead of
	# serving a cached block; without it a long gauge cadence would stale the numbers a run is judged on.
	Engine.set_meta("la_run_frames", run_frames)
	for arg_v in OS.get_cmdline_user_args():
		var arg: String = String(arg_v)
		if arg.begins_with(ARG_SHOOT_FRAMES):
			shoot_frames = maxi(1, int(arg.substr(ARG_SHOOT_FRAMES.length())))
		elif arg.begins_with(ARG_SHOOT):
			shoot_path = arg.substr(ARG_SHOOT.length())
