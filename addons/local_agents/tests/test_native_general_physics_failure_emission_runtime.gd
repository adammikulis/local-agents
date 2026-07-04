@tool
extends RefCounted

const ExtensionLoader := preload("res://addons/local_agents/runtime/LocalAgentsExtensionLoader.gd")
const NativeComputeBridge := preload("res://addons/local_agents/simulation/controller/NativeComputeBridge.gd")
const SimulationControllerScript := preload("res://addons/local_agents/simulation/SimulationController.gd")
const SimulationVoxelTerrainMutatorScript := preload("res://addons/local_agents/simulation/controller/SimulationVoxelTerrainMutator.gd")
const WorldGenConfigScript := preload("res://addons/local_agents/configuration/parameters/simulation/WorldGenConfigResource.gd")
const PIPELINE_STAGE_NAME := "wave_a_continuity"

const BASE_MASS := [1.0, 1.1]
const BASE_PRESSURE := [102.0, 118.0]
const BASE_TEMPERATURE := [292.0, 308.0]
const BASE_VELOCITY := [0.45, 0.55]
const BASE_DENSITY := [1.0, 1.15]
const BASE_TOPOLOGY := [[1], [0]]
const REQUIRED_NOISE_SCALAR_KEYS := ["noise_frequency", "noise_octaves", "noise_lacunarity"]
const OPTIONAL_NOISE_GAIN_KEYS := ["noise_gain", "noise_persistence"]

func run_test(tree: SceneTree) -> bool:
	if not ExtensionLoader.ensure_initialized():
		push_error("LocalAgentsExtensionLoader failed to initialize: %s" % ExtensionLoader.get_error())
		return false
	if not Engine.has_singleton("LocalAgentsSimulationCore"):
		push_error("LocalAgentsSimulationCore singleton unavailable for failure emission runtime test.")
		return false

	var core := Engine.get_singleton("LocalAgentsSimulationCore")
	if core == null:
		push_error("LocalAgentsSimulationCore singleton was null.")
		return false

	var configured := bool(core.call("configure", _build_config()))
	if not _assert(configured, "LocalAgentsSimulationCore.configure() must succeed for failure emission runtime test setup."):
		return false

	var ok := true
	ok = _test_directional_impact_emits_cleave_with_deterministic_payload(tree, core) and ok
	ok = _test_voxel_chunk_projectile_impact_activates_native_failure(tree, core) and ok
	ok = _test_low_directionality_emits_fracture(tree, core) and ok
	ok = _test_bridge_dispatch_syncs_projectile_contacts_each_pulse(core) and ok
	if ok:
		print("Native generalized physics failure emission runtime tests passed (directional cleave + fracture).")
	return ok

func _test_voxel_chunk_projectile_impact_activates_native_failure(tree: SceneTree, core: Object) -> bool:
	var payload := _build_base_payload()
	payload["inputs"]["stress"] = 1.0
	payload["inputs"]["cohesion"] = 1.0
	var projectile_rows := _build_directional_contact_rows()
	for index in range(projectile_rows.size()):
		var row_variant = projectile_rows[index]
		if row_variant is Dictionary:
			var row := row_variant as Dictionary
			row["projectile_kind"] = "voxel_chunk"
			row["projectile_density_tag"] = "dense"
			row["projectile_hardness_tag"] = "hard"
			row["failure_emission_profile"] = "dense_hard_voxel_chunk"
			projectile_rows[index] = row
	var rows_for_test := projectile_rows
	payload["physics_contacts"] = rows_for_test

	var result: Dictionary = core.call("execute_environment_stage", PIPELINE_STAGE_NAME, payload.duplicate(true))
	var plan := _extract_failure_emission(result)
	var ok := true
	ok = _assert(not plan.is_empty(), "Voxel-chunk projectile contacts should emit a native failure-emission plan.") and ok
	ok = _assert(int(plan.get("planned_op_count", 0)) > 0, "Voxel-chunk projectile contacts should generate at least one op_payload for terrain damage.") and ok
	var op_payload := _extract_first_op_payload(plan)
	ok = _assert(not op_payload.is_empty(), "Voxel-chunk projectile failure emission should include a first op payload.") and ok
	if not op_payload.is_empty():
		ok = _assert(
			String(op_payload.get("operation", "")) == "fracture" or String(op_payload.get("operation", "")) == "cleave",
			"Voxel-chunk projectile failure emission should produce a fracture or cleave op."
		) and ok
		ok = _assert(float(op_payload.get("impact_signal", 0.0)) > 0.0, "Voxel-chunk projectile failure emission payload should report a positive impact_signal.") and ok
	var mutation := _apply_native_mutation(tree, plan)
	ok = _assert_native_mutation_executed(mutation, "Voxel-chunk projectile failure plan execution") and ok
	return ok

func _test_bridge_dispatch_syncs_projectile_contacts_each_pulse(core: Object) -> bool:
	core.call("reset")
	var bridge_stage_name := PIPELINE_STAGE_NAME
	var payload := _build_base_payload()
	payload["physics_contacts"] = _build_directional_contact_rows()
	var first_dispatch: Dictionary = NativeComputeBridge.dispatch_environment_stage(bridge_stage_name, payload.duplicate(true))
	var ok := true
	if not bool(first_dispatch.get("ok", false)):
		var first_error := String(first_dispatch.get("error", ""))
		ok = _assert(
			first_error in ["gpu_required", "gpu_unavailable", "native_required", "native_unavailable", "dispatch_failed"],
			"Bridge dispatch must fail fast with typed native/GPU requirement errors when unavailable (error=%s)." % first_error
		) and ok
		return ok
	var first_snapshot_variant = core.call("get_physics_contact_snapshot")
	ok = _assert(first_snapshot_variant is Dictionary, "Core should expose physics contact snapshot after bridge dispatch.") and ok
	if first_snapshot_variant is Dictionary:
		var first_snapshot := first_snapshot_variant as Dictionary
		ok = _assert(int(first_snapshot.get("buffered_count", 0)) == payload["physics_contacts"].size(), "Bridge dispatch should ingest all projectile contacts into native core buffer.") and ok
		ok = _assert(float(first_snapshot.get("total_relative_speed", 0.0)) > 0.0, "Bridge dispatch should preserve non-zero projectile relative speed signal.") and ok
	var second_dispatch: Dictionary = NativeComputeBridge.dispatch_environment_stage(bridge_stage_name, _build_base_payload())
	ok = _assert(
		bool(second_dispatch.get("ok", false)),
		"Bridge dispatch without contacts should still succeed (error=%s)." % String(second_dispatch.get("error", ""))
	) and ok
	var second_snapshot_variant = core.call("get_physics_contact_snapshot")
	ok = _assert(second_snapshot_variant is Dictionary, "Core should expose physics contact snapshot after no-contact pulse.") and ok
	if second_snapshot_variant is Dictionary:
		var second_snapshot := second_snapshot_variant as Dictionary
		ok = _assert(int(second_snapshot.get("buffered_count", 0)) == 0, "Bridge dispatch should clear native contact buffer when no projectile contacts are present.") and ok
	return ok

func _test_directional_impact_emits_cleave_with_deterministic_payload(tree: SceneTree, core: Object) -> bool:
	core.call("reset")
	var payload := _build_base_payload()
	payload["physics_contacts"] = _build_directional_contact_rows()
	payload["inputs"]["stress"] = 1.0
	payload["inputs"]["cohesion"] = 1.0

	var first_result: Dictionary = core.call("execute_environment_stage", PIPELINE_STAGE_NAME, payload.duplicate(true))
	core.call("reset")
	var second_result: Dictionary = core.call("execute_environment_stage", PIPELINE_STAGE_NAME, payload.duplicate(true))

	var first_plan := _extract_failure_emission(first_result)
	var second_plan := _extract_failure_emission(second_result)
	var ok := true
	ok = _assert(not first_plan.is_empty(), "Directional impact path should emit voxel failure emission against environment stage.") and ok
	ok = _assert(int(first_plan.get("planned_op_count", 0)) > 0, "Directional impact path should emit at least one voxel op.") and ok

	var first_op := _extract_first_op_payload(first_plan)
	var second_op := _extract_first_op_payload(second_plan)
	ok = _assert(not first_op.is_empty(), "Directional impact path should provide first op payload.") and ok
	ok = _assert(not second_op.is_empty(), "Directional impact replay should provide first op payload.") and ok
	ok = _assert(String(first_op.get("operation", "")) == "cleave", "Directional impact path should emit cleave operation.") and ok
	ok = _assert(String(second_op.get("operation", "")) == "cleave", "Directional impact replay should emit cleave operation.") and ok

	for key in ["operation", "reason", "contact_signal", "impact_work"]:
		ok = _assert(first_op.has(key), "Directional cleave op payload should include '%s'." % key) and ok
		ok = _assert(second_op.has(key), "Directional cleave replay payload should include '%s'." % key) and ok

	ok = _assert(
		first_op.has("impact_normal") or first_op.has("direction") or first_op.has("plane_normal") or first_op.has("axis"),
		"Directional cleave op payload should expose a directional vector field."
	) and ok
	ok = _assert(_is_numeric(first_op.get("contact_signal", 0.0)), "Directional cleave contact_signal should be numeric.") and ok
	ok = _assert(_is_numeric(first_op.get("impact_work", 0.0)), "Directional cleave impact_work should be numeric.") and ok
	ok = _assert_noise_payload_present(first_op, "Directional cleave op payload") and ok
	ok = _assert_noise_payload_present(second_op, "Directional cleave replay payload") and ok
	ok = _assert_environment_stage_driver(first_plan, "Directional cleave plan") and ok
	ok = _assert_environment_stage_driver(second_plan, "Directional cleave replay plan") and ok
	var first_mutation := _apply_native_mutation(tree, first_plan)
	var second_mutation := _apply_native_mutation(tree, second_plan)
	ok = _assert_native_mutation_executed(first_mutation, "Directional cleave plan execution") and ok
	ok = _assert_native_mutation_executed(second_mutation, "Directional cleave replay execution") and ok
	ok = _assert_native_mutation_replay_stable(first_mutation, second_mutation, "Directional cleave execution replay") and ok

	ok = _assert(String(first_op.get("operation", "")) == String(second_op.get("operation", "")), "Directional cleave operation should be deterministic across replay.") and ok
	ok = _assert(String(first_op.get("reason", "")) == String(second_op.get("reason", "")), "Directional cleave reason should be deterministic across replay.") and ok
	ok = _assert(abs(float(first_op.get("contact_signal", 0.0)) - float(second_op.get("contact_signal", 0.0))) <= 1.0e-12, "Directional cleave contact_signal should be deterministic across replay.") and ok
	ok = _assert(abs(float(first_op.get("impact_work", 0.0)) - float(second_op.get("impact_work", 0.0))) <= 1.0e-12, "Directional cleave impact_work should be deterministic across replay.") and ok
	ok = _assert_noise_payload_replay_stable(first_op, second_op, "Directional cleave replay") and ok
	return ok

func _test_low_directionality_emits_fracture(tree: SceneTree, core: Object) -> bool:
	core.call("reset")
	var payload := _build_base_payload()
	payload["physics_contacts"] = _build_low_directionality_contact_rows()
	payload["inputs"]["stress"] = 3.5e8
	payload["inputs"]["strain"] = 0.52
	payload["inputs"]["cohesion"] = 0.1
	payload["inputs"]["normal_force"] = 1800.0

	var first_result: Dictionary = core.call("execute_environment_stage", PIPELINE_STAGE_NAME, payload.duplicate(true))
	core.call("reset")
	var second_result: Dictionary = core.call("execute_environment_stage", PIPELINE_STAGE_NAME, payload.duplicate(true))

	var first_plan := _extract_failure_emission(first_result)
	var second_plan := _extract_failure_emission(second_result)
	var first_op := _extract_first_op_payload(first_plan)
	var second_op := _extract_first_op_payload(second_plan)
	var ok := true
	ok = _assert(not first_plan.is_empty(), "Low-directionality/non-impact path should emit a native fracture plan.") and ok
	ok = _assert(int(first_plan.get("planned_op_count", 0)) > 0, "Low-directionality/non-impact path should emit at least one native voxel op.") and ok
	ok = _assert(not first_op.is_empty(), "Low-directionality/non-impact path should provide first op payload.") and ok
	ok = _assert(not second_plan.is_empty(), "Low-directionality/non-impact replay should emit a native fracture plan.") and ok
	ok = _assert(int(second_plan.get("planned_op_count", 0)) > 0, "Low-directionality/non-impact replay should emit at least one native voxel op.") and ok
	ok = _assert(not second_op.is_empty(), "Low-directionality/non-impact replay should provide first op payload.") and ok
	ok = _assert(String(first_op.get("operation", "")) == "fracture", "Low-directionality/non-impact path should emit fracture operation.") and ok
	ok = _assert(String(second_op.get("operation", "")) == "fracture", "Low-directionality/non-impact replay should emit fracture operation.") and ok
	ok = _assert_environment_stage_driver(first_plan, "Low-directionality fracture plan") and ok
	ok = _assert_environment_stage_driver(second_plan, "Low-directionality fracture replay plan") and ok
	var first_mutation := _apply_native_mutation(tree, first_plan)
	var second_mutation := _apply_native_mutation(tree, second_plan)
	ok = _assert_native_mutation_executed(first_mutation, "Low-directionality fracture plan execution") and ok
	ok = _assert_native_mutation_executed(second_mutation, "Low-directionality fracture replay execution") and ok
	ok = _assert_native_mutation_replay_stable(first_mutation, second_mutation, "Low-directionality fracture execution replay") and ok
	return ok

func _build_base_payload() -> Dictionary:
	return {
		"delta": 1.0,
		"inputs": {
			"mass_field": BASE_MASS.duplicate(true),
			"pressure_field": BASE_PRESSURE.duplicate(true),
			"temperature_field": BASE_TEMPERATURE.duplicate(true),
			"velocity_field": BASE_VELOCITY.duplicate(true),
			"density_field": BASE_DENSITY.duplicate(true),
			"neighbor_topology": BASE_TOPOLOGY.duplicate(true),
		},
	}

func _build_config() -> Dictionary:
	return {
		"impact_fracture": {
			"impact_signal_gain": 1.5,
			"watch_signal_threshold": 0.45,
			"active_signal_threshold": 0.95,
			"fracture_radius_base": 1.5,
			"fracture_radius_gain": 6.0,
			"fracture_radius_max": 20.0,
			"fracture_value_softness": 0.5,
			"fracture_value_cap": 1.0,
		}
	}

func _build_directional_contact_rows() -> Array:
	return [
		{
			"body_a": "body_a",
			"body_b": "body_b",
			"shape_a": 0,
			"shape_b": 1,
			"frame": 1,
			"contact_impulse": 9.0,
			"relative_speed": 11.0,
			"body_mass": 3.0,
			"collider_mass": 2.0,
			"contact_normal": Vector3(1.0, 0.0, 0.0),
			"contact_point": Vector3(3.0, 4.0, 1.0),
		},
		{
			"body_a": "body_a",
			"body_b": "body_b",
			"shape_a": 0,
			"shape_b": 1,
			"frame": 1,
			"contact_impulse": 7.5,
			"relative_speed": 9.5,
			"body_mass": 2.7,
			"collider_mass": 1.8,
			"contact_normal": Vector3(1.0, 0.0, 0.0),
			"contact_point": Vector3(4.0, 4.0, 1.0),
		},
	]

func _build_low_directionality_contact_rows() -> Array:
	return [
		{
			"body_a": "body_c",
			"body_b": "body_d",
			"shape_a": 1,
			"shape_b": 2,
			"frame": 1,
			"contact_impulse": 4.0,
			"relative_speed": 5.0,
			"body_mass": 2.0,
			"collider_mass": 2.0,
			"contact_normal": Vector3(1.0, 0.0, 0.0),
			"contact_point": Vector3(2.0, 3.0, 1.0),
		},
		{
			"body_a": "body_c",
			"body_b": "body_d",
			"shape_a": 1,
			"shape_b": 2,
			"frame": 1,
			"contact_impulse": 4.0,
			"relative_speed": 5.0,
			"body_mass": 2.0,
			"collider_mass": 2.0,
			"contact_normal": Vector3(-1.0, 0.0, 0.0),
			"contact_point": Vector3(2.0, 3.0, 2.0),
		},
	]

func _extract_failure_emission(result: Dictionary) -> Dictionary:
	for key in ["voxel_failure_emission", "result_fields", "result", "payload", "execution", "voxel_result", "source"]:
		var emission = result.get(key, {})
		if key == "voxel_failure_emission" and emission is Dictionary:
			return emission
		if emission is Dictionary:
			var nested = _extract_failure_emission(emission as Dictionary)
			if not nested.is_empty():
				return nested
	return {}

func _extract_first_op_payload(plan: Dictionary) -> Dictionary:
	var payloads = plan.get("op_payloads", [])
	if not (payloads is Array):
		return {}
	if payloads.is_empty():
		return {}
	if payloads[0] is Dictionary:
		return payloads[0]
	return {}

func _apply_native_mutation(tree: SceneTree, plan: Dictionary) -> Dictionary:
	# Authoritative voxel execution is native/GPU-only; headless has no GPU RenderingDevice,
	# so the emitted native_ops are executed through the native terrain mutator
	# (native_ops_payload_primary), the headless-capable authoritative mutation surface.
	var op_payloads_variant = plan.get("op_payloads", [])
	var native_ops: Array = op_payloads_variant if op_payloads_variant is Array else []
	var controller := SimulationControllerScript.new()
	tree.root.add_child(controller)
	controller.configure("seed-failure-emission-runtime-path", false, false)
	var config := WorldGenConfigScript.new()
	config.map_width = 20
	config.map_height = 20
	config.voxel_world_height = 34
	config.voxel_sea_level = 10
	var setup: Dictionary = controller.configure_environment(config)
	if not bool(setup.get("ok", false)):
		controller.queue_free()
		return {"changed": false, "error": "environment_setup_failed", "changed_tiles": [], "changed_chunks": []}
	var mutation: Dictionary = SimulationVoxelTerrainMutatorScript.apply_native_voxel_stage_delta(
		controller,
		1,
		{"native_ops": native_ops, "changed_chunks": []})
	controller.queue_free()
	return mutation

func _is_numeric(value: Variant) -> bool:
	return value is int or value is float

func _assert_environment_stage_driver(plan: Dictionary, label: String) -> bool:
	var ok := true
	ok = _assert(String(plan.get("target_domain", "")) == "environment", "%s should target the environment voxel domain." % label) and ok
	ok = _assert(String(plan.get("stage_name", "")) == "physics_failure_emission", "%s should execute the physics_failure_emission stage." % label) and ok
	ok = _assert(
		String(plan.get("op_kind", "")) == "cleave" or String(plan.get("op_kind", "")) == "fracture",
		"%s should emit only cleave/fracture op kinds (no local carve path)." % label
	) and ok
	return ok

func _assert_native_mutation_executed(mutation: Dictionary, label: String) -> bool:
	var ok := true
	ok = _assert(bool(mutation.get("changed", false)), "%s should mutate the environment wall via the native voxel op payload path." % label) and ok
	ok = _assert(String(mutation.get("mutation_path", "")) == "native_ops_payload_primary", "%s should route through the canonical native_ops_payload_primary mutation path." % label) and ok
	ok = _assert(String(mutation.get("mutation_path_state", "")) == "success", "%s should complete successfully." % label) and ok
	ok = _assert(String(mutation.get("error", "")) == "", "%s should report an empty typed error code on success." % label) and ok
	var changed_tiles_variant = mutation.get("changed_tiles", [])
	var changed_tiles: Array = changed_tiles_variant if changed_tiles_variant is Array else []
	ok = _assert(changed_tiles.size() > 0, "%s should report changed voxel operations (changed_tiles)." % label) and ok
	var changed_chunks_variant = mutation.get("changed_chunks", [])
	var changed_chunks: Array = changed_chunks_variant if changed_chunks_variant is Array else []
	ok = _assert(changed_chunks.size() > 0, "%s should include at least one changed chunk." % label) and ok
	return ok

func _assert_native_mutation_replay_stable(first_mutation: Dictionary, second_mutation: Dictionary, label: String) -> bool:
	var ok := true
	var first_tiles_variant = first_mutation.get("changed_tiles", [])
	var second_tiles_variant = second_mutation.get("changed_tiles", [])
	var first_tiles: Array = first_tiles_variant if first_tiles_variant is Array else []
	var second_tiles: Array = second_tiles_variant if second_tiles_variant is Array else []
	ok = _assert(first_tiles.size() == second_tiles.size(), "%s should preserve changed_tiles count across replay." % label) and ok
	ok = _assert(first_tiles == second_tiles, "%s should preserve deterministic changed_tiles payload across replay." % label) and ok
	ok = _assert(
		first_mutation.get("changed_chunks", []) == second_mutation.get("changed_chunks", []),
		"%s should preserve changed_chunks ordering across replay." % label
	) and ok
	return ok

func _assert_noise_payload_present(op_payload: Dictionary, label: String) -> bool:
	var ok := true
	ok = _assert(op_payload.has("noise_seed"), "%s should include 'noise_seed'." % label) and ok
	ok = _assert(_is_numeric(op_payload.get("noise_seed", 0)), "%s noise_seed should be numeric." % label) and ok
	for key in REQUIRED_NOISE_SCALAR_KEYS:
		ok = _assert(op_payload.has(key), "%s should include '%s'." % [label, key]) and ok
		ok = _assert(_is_numeric(op_payload.get(key, 0.0)), "%s %s should be numeric." % [label, key]) and ok
	var gain_present := false
	for key in OPTIONAL_NOISE_GAIN_KEYS:
		if op_payload.has(key):
			gain_present = true
			ok = _assert(_is_numeric(op_payload.get(key, 0.0)), "%s %s should be numeric." % [label, key]) and ok
	ok = _assert(
		gain_present,
		"%s should include one gain scalar ('noise_gain' or 'noise_persistence')." % label
	) and ok
	return ok

func _assert_noise_payload_replay_stable(first_op: Dictionary, second_op: Dictionary, label: String) -> bool:
	var ok := true
	ok = _assert(
		int(first_op.get("noise_seed", -1)) == int(second_op.get("noise_seed", -2)),
		"%s should preserve deterministic noise_seed." % label
	) and ok
	for key in REQUIRED_NOISE_SCALAR_KEYS:
		ok = _assert(
			abs(float(first_op.get(key, 0.0)) - float(second_op.get(key, 0.0))) <= 1.0e-12,
			"%s should preserve deterministic %s." % [label, key]
		) and ok
	var first_gain_key := ""
	for key in OPTIONAL_NOISE_GAIN_KEYS:
		if first_op.has(key):
			first_gain_key = key
			break
	var second_gain_key := ""
	for key in OPTIONAL_NOISE_GAIN_KEYS:
		if second_op.has(key):
			second_gain_key = key
			break
	ok = _assert(first_gain_key != "", "%s should include an optional gain scalar in first payload." % label) and ok
	ok = _assert(second_gain_key != "", "%s should include an optional gain scalar in replay payload." % label) and ok
	ok = _assert(first_gain_key == second_gain_key, "%s should preserve selected gain scalar key across replay." % label) and ok
	if first_gain_key != "" and second_gain_key != "":
		ok = _assert(
			abs(float(first_op.get(first_gain_key, 0.0)) - float(second_op.get(second_gain_key, 0.0))) <= 1.0e-12,
			"%s should preserve deterministic %s." % [label, first_gain_key]
		) and ok
	return ok

func _assert(condition: bool, message: String) -> bool:
	if not condition:
		push_error(message)
	return condition
