@tool
extends RefCounted

const SimulationControllerScript = preload("res://addons/local_agents/simulation/SimulationController.gd")
const SimulationVoxelTerrainMutatorScript = preload("res://addons/local_agents/simulation/controller/SimulationVoxelTerrainMutator.gd")
const WorldGenConfigScript = preload("res://addons/local_agents/configuration/parameters/simulation/WorldGenConfigResource.gd")

func run_test(tree: SceneTree) -> bool:
	var controller = SimulationControllerScript.new()
	tree.get_root().add_child(controller)
	controller.configure("seed-projectile-direct-impact-guarantee", false, false)

	var config = WorldGenConfigScript.new()
	config.map_width = 20
	config.map_height = 20
	config.voxel_world_height = 34
	config.voxel_sea_level = 10
	var setup: Dictionary = controller.configure_environment(config)
	if not bool(setup.get("ok", false)):
		controller.queue_free()
		push_error("Environment setup failed for projectile direct-impact mutation guarantee test.")
		return false

	var target := _pick_target_column(controller._environment_snapshot)
	if target.is_empty():
		controller.queue_free()
		push_error("Failed to locate a target voxel column for direct-impact mutation guarantee test.")
		return false

	var tile_id := String(target.get("tile_id", ""))
	var tile_x := int(target.get("x", 0))
	var tile_z := int(target.get("z", 0))
	var start_surface := int(target.get("surface_y", 0))
	var payload := {
		"physics_contacts": [
			{
				"body_id": 501,
				"projectile_kind": "voxel_chunk",
				"contact_point": Vector3(float(tile_x), float(start_surface), float(tile_z)),
				"contact_impulse": 32.0,
				"relative_speed": 40.0,
				"projectile_radius": 0.4,
			}
		],
	}

	var mutation: Dictionary = SimulationVoxelTerrainMutatorScript.apply_native_voxel_stage_delta(controller, 1, payload)
	var ok := true
	ok = _assert(bool(mutation.get("changed", false)), "Direct-impact fallback should mutate terrain when confirmed projectile hit has no native voxel op payloads.") and ok
	var changed_tiles_variant = mutation.get("changed_tiles", [])
	var changed_tiles: Array = changed_tiles_variant if changed_tiles_variant is Array else []
	ok = _assert(changed_tiles.has(tile_id), "Direct-impact fallback should include impacted contact tile in changed_tiles list.") and ok
	var end_surface := _surface_y_for_tile(controller._environment_snapshot, tile_id)
	ok = _assert(end_surface < start_surface, "Direct-impact fallback should lower impacted tile surface for visible destruction.") and ok

	controller.queue_free()
	if ok:
		print("Projectile direct-impact mutation guarantee test passed.")
	return ok

func _pick_target_column(environment_snapshot: Dictionary) -> Dictionary:
	var voxel_world_variant = environment_snapshot.get("voxel_world", {})
	if not (voxel_world_variant is Dictionary):
		return {}
	var voxel_world = voxel_world_variant as Dictionary
	var columns_variant = voxel_world.get("columns", [])
	if not (columns_variant is Array):
		return {}
	for column_variant in (columns_variant as Array):
		if not (column_variant is Dictionary):
			continue
		var column = column_variant as Dictionary
		var surface := int(column.get("surface_y", 0))
		if surface <= 1:
			continue
		var x := int(column.get("x", 0))
		var z := int(column.get("z", 0))
		return {
			"x": x,
			"z": z,
			"surface_y": surface,
			"tile_id": "%d:%d" % [x, z],
		}
	return {}

func _surface_y_for_tile(environment_snapshot: Dictionary, tile_id: String) -> int:
	var voxel_world_variant = environment_snapshot.get("voxel_world", {})
	if not (voxel_world_variant is Dictionary):
		return 0
	var voxel_world = voxel_world_variant as Dictionary
	var columns_variant = voxel_world.get("columns", [])
	if not (columns_variant is Array):
		return 0
	for column_variant in (columns_variant as Array):
		if not (column_variant is Dictionary):
			continue
		var column = column_variant as Dictionary
		if "%d:%d" % [int(column.get("x", 0)), int(column.get("z", 0))] == tile_id:
			return int(column.get("surface_y", 0))
	return 0

func _assert(condition: bool, message: String) -> bool:
	if not condition:
		push_error(message)
	return condition
