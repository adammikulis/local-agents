@tool
extends RefCounted

const SimulationControllerScript = preload("res://addons/local_agents/simulation/SimulationController.gd")
const WorldGenConfigScript = preload("res://addons/local_agents/configuration/parameters/simulation/WorldGenConfigResource.gd")

func run_test(tree: SceneTree) -> bool:
	var first = _run_trace(tree)
	if not bool(first.get("ok", false)):
		push_error(String(first.get("error", "first_trace_failed")))
		return false
	var second = _run_trace(tree)
	if not bool(second.get("ok", false)):
		push_error(String(second.get("error", "second_trace_failed")))
		return false
	var left = JSON.stringify(first.get("trace", []), "", false, true)
	var right = JSON.stringify(second.get("trace", []), "", false, true)
	if left != right:
		push_error("Environment signal trace diverged between deterministic runs")
		return false
	if int(first.get("changed_ticks", 0)) <= 0:
		push_error("No erosion delta ticks observed in environment signal determinism test")
		return false
	print("Environment signal determinism test passed.")
	return true

func _run_trace(tree: SceneTree) -> Dictionary:
	var controller = SimulationControllerScript.new()
	tree.get_root().add_child(controller)
	controller.configure("seed-env-signals", false, false)

	var config = WorldGenConfigScript.new()
	config.map_width = 22
	config.map_height = 22
	config.voxel_world_height = 32
	config.voxel_sea_level = 9
	var setup: Dictionary = controller.configure_environment(config)
	if not bool(setup.get("ok", false)):
		controller.queue_free()
		return {"ok": false, "error": "environment_setup_failed"}

	var trace: Array = []
	var changed_ticks = 0
	for tick in range(1, 37):
		var result: Dictionary = controller.process_tick(tick, 1.0)
		if not bool(result.get("ok", false)):
			controller.queue_free()
			return {"ok": false, "error": "tick_failed_%d" % tick}
		var state: Dictionary = result.get("state", {})
		var signals: Dictionary = state.get("environment_signals", {})
		if signals.is_empty():
			controller.queue_free()
			return {"ok": false, "error": "missing_environment_signals_%d" % tick}
		var changed_tiles: Array = signals.get("erosion_changed_tiles", [])
		changed_tiles.sort()
		var changed_flag = bool(signals.get("erosion_changed", false))
		if changed_tiles.is_empty() == changed_flag:
			controller.queue_free()
			return {"ok": false, "error": "changed_flag_mismatch_%d" % tick}
		if changed_flag:
			changed_ticks += 1
		var weather: Dictionary = signals.get("weather_snapshot", {})
		var solar: Dictionary = signals.get("solar_snapshot", {})
		trace.append({
			"tick": tick,
			"changed": changed_flag,
			"tiles": changed_tiles,
			"avg_rain": snappedf(float(weather.get("avg_rain_intensity", 0.0)), 0.0001),
			"avg_cloud": snappedf(float(weather.get("avg_cloud_cover", 0.0)), 0.0001),
			"avg_sun": snappedf(float(solar.get("avg_insolation", 0.0)), 0.0001),
			"avg_heat": snappedf(float(solar.get("avg_heat_load", 0.0)), 0.0001),
		})

	controller.queue_free()
	return {
		"ok": true,
		"trace": trace,
		"changed_ticks": changed_ticks,
	}

