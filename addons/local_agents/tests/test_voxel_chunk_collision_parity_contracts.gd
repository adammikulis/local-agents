@tool
extends RefCounted

const WORLD_SIMULATION_GD_PATH := "res://addons/local_agents/scenes/simulation/controllers/WorldSimulation.gd"
const WORLD_ENVIRONMENT_SYNC_CONTROLLER_GD_PATH := "res://addons/local_agents/scenes/simulation/controllers/world/WorldEnvironmentSyncController.gd"
const ENVIRONMENT_SIGNAL_SNAPSHOT_RESOURCE_GD_PATH := "res://addons/local_agents/configuration/parameters/simulation/EnvironmentSignalSnapshotResource.gd"
const TERRAIN_RENDERER_GD_PATH := "res://addons/local_agents/scenes/simulation/controllers/renderers/TerrainRenderer.gd"

func run_test(_tree: SceneTree) -> bool:
	var ok := true
	ok = _test_dead_local_projectile_contact_carve_symbols_removed_runtime_path() and ok
	ok = _test_erosion_changed_chunks_propagated_through_resource_sync_controller() and ok
	ok = _test_terrain_renderer_chunk_collision_parity_hooks_in_rebuild_lifecycle() and ok
	if ok:
		print("Voxel chunk collision parity source contracts passed (runtime symbol removal + erosion chunk propagation + terrain collision hooks).")
	return ok

func _test_dead_local_projectile_contact_carve_symbols_removed_runtime_path() -> bool:
	var world_simulation_source := _read_script_source(WORLD_SIMULATION_GD_PATH)
	if world_simulation_source == "":
		return false
	var ok := true
	ok = _assert(
		not world_simulation_source.contains("sample_active_projectile_contacts"),
		"Runtime path contract must remove dead local projectile-contact carve sampler symbol."
	) and ok
	ok = _assert(
		not world_simulation_source.contains("ingest_physics_contacts"),
		"Runtime path contract must remove dead local projectile-contact carve ingest symbol."
	) and ok
	return ok

func _test_erosion_changed_chunks_propagated_through_resource_sync_controller() -> bool:
	var resource_source := _read_script_source(ENVIRONMENT_SIGNAL_SNAPSHOT_RESOURCE_GD_PATH)
	if resource_source == "":
		return false
	var sync_controller_source := _read_script_source(WORLD_ENVIRONMENT_SYNC_CONTROLLER_GD_PATH)
	if sync_controller_source == "":
		return false
	var world_simulation_source := _read_script_source(WORLD_SIMULATION_GD_PATH)
	if world_simulation_source == "":
		return false

	var ok := true
	ok = _assert(resource_source.contains("@export var erosion_changed_chunks: Array = []"), "Environment signal resource contract must declare erosion_changed_chunks export.") and ok
	ok = _assert(resource_source.contains("\"erosion_changed_chunks\": erosion_changed_chunks.duplicate(true),"), "Environment signal resource contract must serialize erosion_changed_chunks through to_dict.") and ok
	ok = _assert(resource_source.contains("var changed_chunks_variant = values.get(\"erosion_changed_chunks\", [])"), "Environment signal resource contract must read erosion_changed_chunks in from_dict.") and ok
	ok = _assert(resource_source.contains("erosion_changed_chunks = changed_chunks_variant.duplicate(true) if changed_chunks_variant is Array else []"), "Environment signal resource contract must deep-copy erosion_changed_chunks in from_dict.") and ok

	ok = _assert(sync_controller_source.contains("snapshot.erosion_changed_chunks = (state.get(\"erosion_changed_chunks\", []) as Array).duplicate(true)"), "WorldEnvironmentSyncController contract must hydrate erosion_changed_chunks from state fallback path.") and ok
	ok = _assert(sync_controller_source.contains("env_signals.erosion_changed_chunks"), "WorldEnvironmentSyncController contract must forward erosion_changed_chunks into generation-delta sync.") and ok

	ok = _assert(world_simulation_source.contains("\"erosion_changed_chunks\": (mutation.get(\"changed_chunks\", []) as Array).duplicate(true),"), "WorldSimulation contract must emit erosion_changed_chunks into environment_signals payload.") and ok
	return ok

func _test_terrain_renderer_chunk_collision_parity_hooks_in_rebuild_lifecycle() -> bool:
	var source := _read_script_source(TERRAIN_RENDERER_GD_PATH)
	if source == "":
		return false
	var ok := true
	ok = _assert(source.contains("_build_chunk_collision_body(chunk_node, by_type)"), "TerrainRenderer rebuild lifecycle contract must invoke chunk collision parity hook for each rebuilt chunk.") and ok
	ok = _assert(source.contains("func _build_chunk_collision_body(chunk_node: Node3D, by_type: Dictionary) -> void:"), "TerrainRenderer contract must define chunk collision parity builder helper.") and ok
	ok = _assert(source.contains("var collision_body := StaticBody3D.new()"), "TerrainRenderer collision parity hook must allocate StaticBody3D for per-chunk collision representation.") and ok
	ok = _assert(source.contains("var shape := CollisionShape3D.new()"), "TerrainRenderer collision parity hook must emit CollisionShape3D rows for collidable voxel blocks.") and ok
	ok = _assert(source.contains("if not _block_type_has_collision(block_type):"), "TerrainRenderer collision parity hook must gate non-collidable block types.") and ok
	ok = _assert(source.contains("if has_collision:"), "TerrainRenderer collision parity hook must attach body only when collidable shapes were emitted.") and ok
	return ok

func _assert(condition: bool, message: String) -> bool:
	if not condition:
		push_error(message)
	return condition

func _read_script_source(script_path: String) -> String:
	var file := FileAccess.open(script_path, FileAccess.READ)
	if file == null:
		_assert(false, "Failed to open source: %s" % script_path)
		return ""
	return file.get_as_text()
