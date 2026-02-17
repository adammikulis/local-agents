@tool
extends RefCounted

const SimulationControllerScript = preload("res://addons/local_agents/simulation/SimulationController.gd")
const SimulationVoxelTerrainMutatorScript = preload("res://addons/local_agents/simulation/controller/SimulationVoxelTerrainMutator.gd")
const WorldGenConfigScript = preload("res://addons/local_agents/configuration/parameters/simulation/WorldGenConfigResource.gd")

func run_test(tree: SceneTree) -> bool:
	var controller = SimulationControllerScript.new()
	tree.get_root().add_child(controller)
	controller.configure("seed-projectile-runtime-path", false, false)

	var config = WorldGenConfigScript.new()
	config.map_width = 20
	config.map_height = 20
	config.voxel_world_height = 34
	config.voxel_sea_level = 10
	var setup: Dictionary = controller.configure_environment(config)
	if not bool(setup.get("ok", false)):
		controller.queue_free()
		push_error("Environment setup failed for projectile voxel runtime-path regression test.")
		return false

	var target := _pick_target_column(controller._environment_snapshot)
	if target.is_empty():
		controller.queue_free()
		push_error("Failed to locate a target voxel column for projectile runtime-path regression test.")
		return false
	var tile_id := String(target.get("tile_id", ""))
	var tile_x := int(target.get("x", 0))
	var tile_z := int(target.get("z", 0))
	var start_surface := int(target.get("surface_y", 0))
	var chunk_size := int(target.get("chunk_size", 12))
	var mutation: Dictionary = SimulationVoxelTerrainMutatorScript.apply_native_voxel_stage_delta(controller, 1, {
		"changed_chunks": [
			{"x": int(floor(float(tile_x) / float(chunk_size))), "y": 0, "z": int(floor(float(tile_z) / float(chunk_size)))}
		],
	})
	var ok := true
	ok = _assert(not bool(mutation.get("changed", false)), "Missing native_ops payload should fail fast and never mutate terrain via native-authoritative path.") and ok
	var changed_tiles_variant = mutation.get("changed_tiles", [])
	var changed_tiles: Array = changed_tiles_variant if changed_tiles_variant is Array else []
	ok = _assert(changed_tiles.is_empty(), "No-mutation path should report an empty changed_tiles list.") and ok
	ok = _assert(String(mutation.get("error", "")) == "native_voxel_op_payload_missing", "Missing native_ops payload should return native_voxel_op_payload_missing.") and ok
	ok = _assert(String(mutation.get("mutation_path", "")) == "native_ops_payload_primary", "Missing native_ops payload should report native_ops_payload_primary mutation_path.") and ok
	ok = _assert(String(mutation.get("mutation_path_state", "")) == "failure", "No-mutation path should report mutation_path_state=failure.") and ok
	ok = _assert(String(mutation.get("details", "")) == "native voxel op payload required; CPU fallback disabled", "Missing native_ops payload should expose deterministic fail-fast details for native-authoritative mutation contract.") and ok
	var failure_paths_variant = mutation.get("failure_paths", [])
	var failure_paths: Array = failure_paths_variant if failure_paths_variant is Array else []
	ok = _assert(failure_paths.size() == 1 and String(failure_paths[0]) == "native_voxel_op_payload_missing", "Missing native_ops payload should return stable failure_paths metadata with only native_voxel_op_payload_missing.") and ok
	var changed_chunks_variant = mutation.get("changed_chunks", [])
	var changed_chunks: Array = changed_chunks_variant if changed_chunks_variant is Array else []
	ok = _assert(changed_chunks.size() == 1 and String(changed_chunks[0]) == "%d:%d" % [int(floor(float(tile_x) / float(chunk_size))), int(floor(float(tile_z) / float(chunk_size)))], "No-contact runtime payload should preserve normalized changed_chunks metadata without CPU-success fallback mutation.") and ok

	var end_surface := _surface_y_for_tile(controller._environment_snapshot, tile_id)
	ok = _assert(end_surface == start_surface, "No-contact runtime payload should leave impacted tile surface unchanged.") and ok

	controller.queue_free()
	if ok:
		print("Projectile voxel destruction runtime-path regression test passed.")
	return ok

func _pick_target_column(environment_snapshot: Dictionary) -> Dictionary:
	var voxel_world_variant = environment_snapshot.get("voxel_world", {})
	if not (voxel_world_variant is Dictionary):
		return {}
	var voxel_world = voxel_world_variant as Dictionary
	var columns_variant = voxel_world.get("columns", [])
	if not (columns_variant is Array):
		return {}
	var chunk_size := maxi(4, int(voxel_world.get("block_rows_chunk_size", 12)))
	var best: Dictionary = {}
	for column_variant in (columns_variant as Array):
		if not (column_variant is Dictionary):
			continue
		var column = column_variant as Dictionary
		var surface := int(column.get("surface_y", 0))
		if surface <= 1:
			continue
		var x := int(column.get("x", 0))
		var z := int(column.get("z", 0))
		best = {
			"x": x,
			"z": z,
			"surface_y": surface,
			"tile_id": "%d:%d" % [x, z],
			"chunk_size": chunk_size,
		}
		break
	return best

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
