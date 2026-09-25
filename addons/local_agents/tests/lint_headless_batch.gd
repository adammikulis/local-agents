extends SceneTree

## ONE HEADLESS LAUNCH FOR EVERY RUNNER THAT ONLY READS TABLES, fenced LA_BATCH_BEGIN=/LA_BATCH_END= so
## lint_capture.sh splits the log per runner and each prints the verdict its gate reads. A runner with
## `_after_frame() -> bool` holds the batch, its fence open, until it answers true.

const RUNNERS: Array = [
	["engine_version", ""],
	["substances", "res://scripts/dump_substances.gd"],
	["element_composition", "res://scripts/check_element_composition.gd"],
	["reaction_balance", "res://scripts/check_reaction_balance.gd"],
	["reaction_rate_units", "res://scripts/check_reaction_rate_units.gd"],
	["reaction_energy", "res://scripts/check_reaction_energy.gd"],
	["faint_young_sun", "res://scripts/check_faint_young_sun.gd"],
	["seed_decisions", "res://scripts/check_seed_decisions.gd"],
	["voxel_grid", "res://addons/local_agents/tests/gate_voxel_grid.gd"],
	["condensed_moduli", "res://addons/local_agents/tests/gate_condensed_moduli.gd"],
	["process_set", "res://addons/local_agents/tests/gate_process_set.gd"],
	["gate_rungs", "res://addons/local_agents/tests/gate_gate_rungs.gd"],
	["process_ui", "res://addons/local_agents/tests/gate_process_ui.gd"],
	["slice_exterior_geom", "res://addons/local_agents/tests/gate_slice_exterior_geom.gd"],
	["shaders_compile", "res://addons/local_agents/tests/gate_shaders_compile.gd"],
	["parse_all", "res://scripts/parse_all_scripts.gd"],
	["hypsometry", "res://scripts/check_hypsometry.gd"],
	["ablate_modules", "res://addons/local_agents/tests/gate_ablate_modules.gd"],
]

var _row: int = 0
var _held: Object = null


func _run(path: String) -> Object:
	var scr: GDScript = load(path)
	if scr == null:
		printerr("lint_headless_batch: %s did not load." % path)
		return null
	var inst: Object = scr.new()
	if inst == null:
		printerr("lint_headless_batch: %s did not instantiate." % path)
		return null
	if inst.has_method("_initialize"):
		inst.call("_initialize")
	return inst


func _initialize() -> void:
	_run_rows()


func _process(_delta: float) -> bool:
	if _held != null and bool(_held.call("_after_frame")):
		_close(_held)
		_held = null
		_run_rows()
	return false


func _run_rows() -> void:
	var version: Dictionary = Engine.get_version_info()
	while _row < RUNNERS.size():
		var path: String = String(RUNNERS[_row][1])
		print("LA_BATCH_BEGIN=%s" % String(RUNNERS[_row][0]))
		if path == "":
			print("ENGINE_VERSION=%d.%d" % [int(version["major"]), int(version["minor"])])
		var inst: Object = _run(path) if path != "" else null
		if inst != null and inst.has_method("_after_frame"):
			_held = inst
			return
		_close(inst)
	quit(0)


func _close(inst: Object) -> void:
	if inst != null and not (inst is RefCounted):
		inst.free()
	print("LA_BATCH_END=%s" % String(RUNNERS[_row][0]))
	_row += 1
