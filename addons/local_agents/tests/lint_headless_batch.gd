extends SceneTree

## ONE HEADLESS LAUNCH FOR EVERY RUNNER THAT ONLY READS TABLES. Output is fenced with
## LA_BATCH_BEGIN=/LA_BATCH_END= so lint_capture.sh can split the log per runner, and each runner
## prints the verdict marker its gate reads.

const RUNNERS: Array = [
	["engine_version", ""],
	["substances", "res://scripts/dump_substances.gd"],
	["element_composition", "res://scripts/check_element_composition.gd"],
	["reaction_balance", "res://scripts/check_reaction_balance.gd"],
	["reaction_rate_units", "res://scripts/check_reaction_rate_units.gd"],
	["reaction_energy", "res://scripts/check_reaction_energy.gd"],
	["faint_young_sun", "res://scripts/check_faint_young_sun.gd"],
	["creature_energy", "res://scripts/check_creature_energy.gd"],
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
	["group_index", "res://addons/local_agents/tests/gate_group_index.gd"],
	["llm_request_ownership", "res://addons/local_agents/tests/test_llm_request_ownership.gd"],
	["llm_http_stream", "res://addons/local_agents/tests/check_llm_http_stream.gd"],
]


func _run(path: String) -> void:
	var scr: GDScript = load(path)
	if scr == null:
		printerr("lint_headless_batch: %s did not load." % path)
		return
	var inst: Object = scr.new()
	if inst == null:
		printerr("lint_headless_batch: %s did not instantiate." % path)
		return
	if inst.has_method("run_test"):
		await inst.call("run_test", self)
	elif inst.has_method("_initialize"):
		inst.call("_initialize")
	if inst.has_method("_after_frame"):
		while not bool(inst.call("_after_frame")):
			await process_frame
	if not (inst is RefCounted):
		inst.free()


func _initialize() -> void:
	call_deferred("_run_all")

func _run_all() -> void:
	var version: Dictionary = Engine.get_version_info()
	for row in RUNNERS:
		var name: String = String(row[0])
		var path: String = String(row[1])
		print("LA_BATCH_BEGIN=%s" % name)
		if path == "":
			print("ENGINE_VERSION=%d.%d" % [int(version["major"]), int(version["minor"])])
		else:
			await _run(path)
		print("LA_BATCH_END=%s" % name)
	quit(0)
