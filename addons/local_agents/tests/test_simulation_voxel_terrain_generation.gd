@tool
extends RefCounted

const SimulationControllerScript = preload("res://addons/local_agents/simulation/SimulationController.gd")
const WorldGenConfigScript = preload("res://addons/local_agents/configuration/parameters/simulation/WorldGenConfigResource.gd")

func run_test(tree: SceneTree) -> bool:
	var controller = SimulationControllerScript.new()
	tree.get_root().add_child(controller)
	controller.configure("seed-voxel-terrain", false, false)

	var config = WorldGenConfigScript.new()
	config.map_width = 20
	config.map_height = 20
	config.voxel_world_height = 34
	config.voxel_sea_level = 12

	var setup: Dictionary = controller.configure_environment(config)
	controller.queue_free()
	if not bool(setup.get("ok", false)):
		push_error("Environment setup failed for voxel terrain generation test")
		return false

	var environment: Dictionary = setup.get("environment", {})
	var voxel_world: Dictionary = environment.get("voxel_world", {})
	var block_rows: Array = voxel_world.get("block_rows", [])
	var block_counts: Dictionary = voxel_world.get("block_type_counts", {})
	if block_rows.is_empty():
		push_error("Voxel terrain generation produced no blocks")
		return false
	if block_counts.is_empty():
		push_error("Voxel terrain generation missing block type counts")
		return false

	for required_type in ["grass", "dirt", "stone", "water"]:
		if int(block_counts.get(required_type, 0)) <= 0:
			push_error("Voxel terrain missing required block type: %s" % required_type)
			return false

	var ore_count = int(block_counts.get("coal_ore", 0)) + int(block_counts.get("copper_ore", 0)) + int(block_counts.get("iron_ore", 0))
	if ore_count <= 0:
		push_error("Voxel terrain did not generate any ore blocks")
		return false

	print("Voxel terrain block counts: %s" % JSON.stringify(block_counts, "", false, true))
	return true
