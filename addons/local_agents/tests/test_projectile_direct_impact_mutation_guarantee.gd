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
	var chunk_size := 12
	var chunk_x := int(floor(float(tile_x) / float(chunk_size)))
	var chunk_z := int(floor(float(tile_z) / float(chunk_size)))
	var changed_chunks = [
		{"x": chunk_x, "z": chunk_z}
	]
	var payload := {
		"native_ops": [
		{
			"sequence_id": 0,
			"x": tile_x,
			"y": start_surface,
			"z": tile_z,
			"operation": "fracture",
			"value": 1.0,
			"radius": 0.0,
			},
		],
		"changed_chunks": changed_chunks,
		"physics_contacts": [
			{
				"body_id": 501,
				"projectile_kind": "voxel_chunk",
				"contact_point": Vector3(float(tile_x) + 0.37, float(start_surface), float(tile_z) + 0.42),
				"contact_impulse": 32.0,
				"relative_speed": 40.0,
				"projectile_radius": 0.4,
			}
		],
	}

	var mutation: Dictionary = SimulationVoxelTerrainMutatorScript.apply_native_voxel_stage_delta(controller, 1, payload)
	var ok := true
	ok = _assert(bool(mutation.get("changed", false)), "Canonical contact-derived native ops path should mutate terrain when projectile contact is confirmed.") and ok
	var changed_tiles_variant = mutation.get("changed_tiles", [])
	var changed_tiles: Array = changed_tiles_variant if changed_tiles_variant is Array else []
	ok = _assert(changed_tiles.size() > 0, "Canonical contact-derived native ops path should return changed_tiles > 0 for confirmed projectile contacts.") and ok
	ok = _assert(changed_tiles.has(tile_id), "Canonical contact-derived native ops path should include impacted contact tile in changed_tiles list.") and ok
	var error_code := String(mutation.get("error", ""))
	ok = _assert(error_code != "native_voxel_stage_no_mutation", "Confirmed projectile contact should not end with native_voxel_stage_no_mutation.") and ok
	ok = _assert(error_code != "native_voxel_op_payload_missing", "Confirmed projectile contact should not end with native_voxel_op_payload_missing.") and ok
	var mutation_path := String(mutation.get("mutation_path", ""))
	ok = _assert(mutation_path == "native_ops_payload_primary", "Confirmed projectile contact should report canonical native_ops_payload_primary mutation path.") and ok
	ok = _assert(String(mutation.get("mutation_path_state", "")) == "success", "Canonical path success should report mutation_path_state=success.") and ok
	ok = _assert(String(mutation.get("error", "")) == "", "Canonical native-authoritative success path should report empty typed error code.") and ok
	var success_failure_paths_variant = mutation.get("failure_paths", [])
	var success_failure_paths: Array = success_failure_paths_variant if success_failure_paths_variant is Array else []
	ok = _assert(success_failure_paths.is_empty(), "Canonical native-authoritative success path should not emit failure_paths metadata.") and ok
	var end_surface := _surface_y_for_tile(controller._environment_snapshot, tile_id)
	ok = _assert(end_surface < start_surface, "Canonical contact-derived native ops path should lower impacted tile surface for visible destruction.") and ok

	var missing_native_ops_mutation: Dictionary = SimulationVoxelTerrainMutatorScript.apply_native_voxel_stage_delta(controller, 2, {
		"physics_contacts": [
			{
				"body_id": 501,
				"projectile_kind": "voxel_chunk",
				"contact_point": Vector3(float(tile_x) + 0.4, float(start_surface), float(tile_z) + 0.4),
				"contact_impulse": 32.0,
				"relative_speed": 40.0,
				"projectile_radius": 0.4,
			}
		],
		"changed_chunks": changed_chunks,
	})
	ok = _assert(not bool(missing_native_ops_mutation.get("changed", false)), "Payloads without native_ops must fail fast and never mutate via native-authoritative path.") and ok
	ok = _assert(String(missing_native_ops_mutation.get("error", "")) == "native_voxel_op_payload_missing", "Payloads without native_ops must return typed native_voxel_op_payload_missing error.") and ok
	ok = _assert(String(missing_native_ops_mutation.get("mutation_path", "")) == "native_ops_payload_primary", "Payloads without native_ops must report native_ops_payload_primary mutation path.") and ok
	ok = _assert(String(missing_native_ops_mutation.get("mutation_path_state", "")) == "failure", "Payloads without native_ops must report mutation_path_state=failure.") and ok
	ok = _assert(String(missing_native_ops_mutation.get("details", "")) == "native voxel op payload required; CPU fallback disabled", "Payloads without native_ops must expose deterministic fail-fast detail for native-authoritative contract.") and ok
	var missing_native_ops_failure_paths_variant = missing_native_ops_mutation.get("failure_paths", [])
	var missing_native_ops_failure_paths: Array = missing_native_ops_failure_paths_variant if missing_native_ops_failure_paths_variant is Array else []
	ok = _assert(missing_native_ops_failure_paths.size() == 1 and String(missing_native_ops_failure_paths[0]) == "native_voxel_op_payload_missing", "Payloads without native_ops must emit only native_voxel_op_payload_missing in failure_paths metadata.") and ok

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
