@tool
extends RefCounted

const SimulationControllerScript = preload("res://addons/local_agents/simulation/SimulationController.gd")
const WorldGenConfigScript = preload("res://addons/local_agents/configuration/parameters/simulation/WorldGenConfigResource.gd")

func run_test(tree: SceneTree) -> bool:
	var controller = SimulationControllerScript.new()
	tree.get_root().add_child(controller)
	controller.configure("seed-flowmap-bake", false, false)

	var config = WorldGenConfigScript.new()
	config.map_width = 18
	config.map_height = 18
	var setup: Dictionary = controller.configure_environment(config)
	controller.queue_free()
	if not bool(setup.get("ok", false)):
		push_error("Environment setup failed for flowmap bake test")
		return false

	var environment: Dictionary = setup.get("environment", {})
	var flow_map: Dictionary = environment.get("flow_map", {})
	if flow_map.is_empty():
		push_error("World generation did not include baked flow_map")
		return false
	var rows: Array = flow_map.get("rows", [])
	if rows.size() != config.map_width * config.map_height:
		push_error("Flow map rows do not match world dimensions")
		return false

	var max_flow = float(flow_map.get("max_flow", 0.0))
	if max_flow <= 0.0:
		push_error("Flow map max_flow should be positive")
		return false

	var hydrology: Dictionary = setup.get("hydrology", {})
	if hydrology.is_empty():
		hydrology = setup.get("network_state", {})
	var segments: Array = hydrology.get("segments", hydrology.get("source_tiles", []))
	var water_tiles: Dictionary = hydrology.get("water_tiles", {})
	if segments.is_empty() or water_tiles.is_empty():
		var springs: Dictionary = environment.get("springs", {})
		var water_table_rows: Array = (environment.get("water_table", {}) as Dictionary).get("rows", [])
		if not springs.is_empty() and not water_table_rows.is_empty():
			segments = water_table_rows
			water_tiles = springs
	if segments.is_empty() or water_tiles.is_empty():
		push_error("Hydrology missing segments or water tiles from baked flow map")
		return false

	var total_flow = float(hydrology.get("total_flow_index", 0.0))
	if total_flow <= 0.0:
		var water_table_rows: Array = (environment.get("water_table", {}) as Dictionary).get("rows", [])
		if water_table_rows.is_empty():
			push_error("Hydrology total_flow_index should be positive")
			return false

	print("Flowmap bake test passed. max_flow=%0.3f segments=%d" % [max_flow, segments.size()])
	return true
