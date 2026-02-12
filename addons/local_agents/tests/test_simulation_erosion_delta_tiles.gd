@tool
extends RefCounted

const SimulationControllerScript = preload("res://addons/local_agents/simulation/SimulationController.gd")
const WorldGenConfigScript = preload("res://addons/local_agents/configuration/parameters/simulation/WorldGenConfigResource.gd")

func run_test(tree: SceneTree) -> bool:
	var controller = SimulationControllerScript.new()
	tree.get_root().add_child(controller)
	controller.configure("seed-erosion-delta", false, false)

	var config = WorldGenConfigScript.new()
	config.map_width = 22
	config.map_height = 22
	config.voxel_world_height = 34
	config.voxel_sea_level = 10
	var setup: Dictionary = controller.configure_environment(config)
	if not bool(setup.get("ok", false)):
		controller.queue_free()
		push_error("Environment setup failed for erosion delta test")
		return false

	var changed_seen = false
	for tick in range(1, 28):
		var result: Dictionary = controller.process_tick(tick, 1.0)
		if not bool(result.get("ok", false)):
			controller.queue_free()
			push_error("Tick processing failed in erosion delta test")
			return false
		var state: Dictionary = result.get("state", {})
		var erosion_snapshot: Dictionary = state.get("erosion_snapshot", {})
		var changed_flag = bool(state.get("erosion_changed", false))
		var changed_tiles: Array = state.get("erosion_changed_tiles", [])
		if changed_tiles.is_empty() != (not changed_flag):
			controller.queue_free()
			push_error("erosion_changed flag does not match erosion_changed_tiles payload")
			return false
		if not changed_tiles.is_empty():
			changed_seen = true
		var erosion_snapshot_tiles: Array = erosion_snapshot.get("changed_tiles", [])
		if erosion_snapshot_tiles.size() != changed_tiles.size():
			controller.queue_free()
			push_error("erosion_snapshot.changed_tiles not synchronized with state erosion_changed_tiles")
			return false

	controller.queue_free()
	if not changed_seen:
		push_error("Erosion delta test observed no changed tiles across sample ticks")
		return false
	print("Erosion delta test passed.")
	return true
