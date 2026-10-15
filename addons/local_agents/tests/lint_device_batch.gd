extends SceneTree

## ONE LAUNCH WITH THE DEVICE FOR EVERY RIG THAT ONLY NEEDS ONE, fenced with
## LA_BATCH_BEGIN=/LA_BATCH_END= so lint_capture.sh splits the log per rig.

const RUNNERS: Array = [
	["bench_hydrostatic_column", "res://addons/local_agents/tests/bench_hydrostatic_column.gd",
		"check_bench_hydrostatic_column.sh"],
	["bench_shock_tube", "res://addons/local_agents/tests/bench_shock_tube.gd",
		"check_bench_shock_tube.sh"],
	["bench_heat_slab", "res://addons/local_agents/tests/bench_heat_slab.gd",
		"check_bench_heat_slab.sh"],
	["bench_darcy", "res://addons/local_agents/tests/bench_darcy.gd", "check_bench_darcy.sh"],
	["bench_grey_atmosphere", "res://addons/local_agents/tests/bench_grey_atmosphere.gd",
		"check_bench_grey_atmosphere.sh"],
	["bench_jeans_escape", "res://addons/local_agents/tests/bench_jeans_escape.gd",
		"check_bench_jeans_escape.sh"],
	["bench_phase_change", "res://addons/local_agents/tests/bench_phase_change.gd",
		"check_bench_phase_change.sh"],
]


## The rung each gate belongs to, off LAProcessSet, so this batch and lib_capture's la_examined read
## one map. A gate no rung names has none, and runs.
func _rung_of(gate: String) -> int:
	for r in LAProcessSet.rungs():
		for g in r["gates"]:
			if String(g) == gate:
				return int(r["rung"])
	return -1


func _run(path: String) -> void:
	var scr: GDScript = load(path)
	if scr == null:
		printerr("lint_device_batch: %s did not load." % path)
		return
	var inst: Object = scr.new()
	if inst == null:
		printerr("lint_device_batch: %s did not instantiate." % path)
		return
	if inst.has_method("_initialize"):
		inst.call("_initialize")
	if not (inst is RefCounted):
		inst.free()


func _initialize() -> void:
	var device: RenderingDevice = RenderingServer.create_local_rendering_device()
	if device == null:
		printerr("lint_device_batch: no RenderingDevice, so no rig ran.")
		print("LA_DEVICE_BATCH_DONE={\"ran\":0,\"device\":false}")
		quit(2)
		return
	device.free()
	var rung: int = int(OS.get_environment("LA_CAPTURE_RUNG"))
	var ran: int = 0
	for row in RUNNERS:
		var name: String = String(row[0])
		var want: int = _rung_of(String(row[2]))
		print("LA_BATCH_BEGIN=%s" % name)
		if want > rung:
			print("LA_BATCH_ABOVE_RUNG=%d" % want)
		else:
			_run(String(row[1]))
			ran += 1
		print("LA_BATCH_END=%s" % name)
	print("LA_DEVICE_BATCH_DONE={\"ran\":%d,\"device\":true}" % ran)
	quit(0)
