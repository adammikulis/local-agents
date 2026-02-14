@tool
extends RefCounted

const ExtensionLoader := preload("res://addons/local_agents/runtime/LocalAgentsExtensionLoader.gd")
const PIPELINE_STAGE_NAME := "wave_a_continuity"

const BASE_MASS := [1.0, 1.1]
const BASE_PRESSURE := [102.0, 118.0]
const BASE_TEMPERATURE := [292.0, 308.0]
const BASE_VELOCITY := [0.45, 0.55]
const BASE_DENSITY := [1.0, 1.15]
const BASE_TOPOLOGY := [[1], [0]]
const REQUIRED_NOISE_SCALAR_KEYS := ["noise_frequency", "noise_octaves", "noise_lacunarity"]
const OPTIONAL_NOISE_GAIN_KEYS := ["noise_gain", "noise_persistence"]

func run_test(_tree: SceneTree) -> bool:
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
	ok = _test_directional_impact_emits_cleave_with_deterministic_payload(core) and ok
	ok = _test_low_directionality_falls_back_to_fracture(core) and ok
	if ok:
		print("Native generalized physics failure emission runtime tests passed (directional cleave + fallback fracture).")
	return ok

func _test_directional_impact_emits_cleave_with_deterministic_payload(core: Object) -> bool:
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
	ok = _assert(String(first_plan.get("status", "")) == "executed", "Directional impact path should execute voxel failure emission against environment stage.") and ok
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
	ok = _assert_execution_mutated_wall(first_plan, "Directional cleave plan execution") and ok
	ok = _assert_execution_mutated_wall(second_plan, "Directional cleave replay execution") and ok
	ok = _assert_execution_replay_stable(first_plan, second_plan, "Directional cleave execution replay") and ok

	ok = _assert(String(first_op.get("operation", "")) == String(second_op.get("operation", "")), "Directional cleave operation should be deterministic across replay.") and ok
	ok = _assert(String(first_op.get("reason", "")) == String(second_op.get("reason", "")), "Directional cleave reason should be deterministic across replay.") and ok
	ok = _assert(abs(float(first_op.get("contact_signal", 0.0)) - float(second_op.get("contact_signal", 0.0))) <= 1.0e-12, "Directional cleave contact_signal should be deterministic across replay.") and ok
	ok = _assert(abs(float(first_op.get("impact_work", 0.0)) - float(second_op.get("impact_work", 0.0))) <= 1.0e-12, "Directional cleave impact_work should be deterministic across replay.") and ok
	ok = _assert_noise_payload_replay_stable(first_op, second_op, "Directional cleave replay") and ok
	return ok

func _test_low_directionality_falls_back_to_fracture(core: Object) -> bool:
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
	var ok := true
	ok = _assert(String(first_plan.get("status", "")) == "executed", "Fallback path should execute voxel failure emission against environment stage.") and ok
	ok = _assert(int(first_plan.get("planned_op_count", 0)) > 0, "Fallback path should emit at least one voxel op.") and ok

	var first_op := _extract_first_op_payload(first_plan)
	var second_op := _extract_first_op_payload(second_plan)
	ok = _assert(not first_op.is_empty(), "Fallback path should provide first op payload.") and ok
	ok = _assert(not second_op.is_empty(), "Fallback replay should provide first op payload.") and ok
	ok = _assert(String(first_op.get("operation", "")) == "fracture", "Low-directionality/non-impact fallback should emit fracture operation.") and ok
	ok = _assert(String(second_op.get("operation", "")) == "fracture", "Low-directionality/non-impact replay should emit fracture operation.") and ok

	for key in ["operation", "reason", "contact_signal", "impact_work", "radius", "value"]:
		ok = _assert(first_op.has(key), "Fallback fracture op payload should include '%s'." % key) and ok
		ok = _assert(second_op.has(key), "Fallback fracture replay payload should include '%s'." % key) and ok

	ok = _assert(_is_numeric(first_op.get("radius", 0.0)), "Fallback fracture radius should be numeric.") and ok
	ok = _assert(_is_numeric(first_op.get("value", 0.0)), "Fallback fracture value should be numeric.") and ok
	ok = _assert(
		abs(float(first_op.get("radius", 0.0)) - float(second_op.get("radius", 0.0))) <= 1.0e-12,
		"Fallback fracture radius should be deterministic across replay."
	) and ok
	ok = _assert(
		abs(float(first_op.get("value", 0.0)) - float(second_op.get("value", 0.0))) <= 1.0e-12,
		"Fallback fracture value should be deterministic across replay."
	) and ok
	ok = _assert_noise_payload_present(first_op, "Fallback fracture op payload") and ok
	ok = _assert_noise_payload_present(second_op, "Fallback fracture replay payload") and ok
	ok = _assert_environment_stage_driver(first_plan, "Fallback fracture plan") and ok
	ok = _assert_environment_stage_driver(second_plan, "Fallback fracture replay plan") and ok
	ok = _assert_execution_mutated_wall(first_plan, "Fallback fracture plan execution") and ok
	ok = _assert_execution_mutated_wall(second_plan, "Fallback fracture replay execution") and ok
	ok = _assert_execution_replay_stable(first_plan, second_plan, "Fallback fracture execution replay") and ok
	ok = _assert_noise_payload_replay_stable(first_op, second_op, "Fallback fracture replay") and ok
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
	var emission = result.get("voxel_failure_emission", {})
	if emission is Dictionary:
		return emission
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

func _extract_execution(plan: Dictionary) -> Dictionary:
	var execution = plan.get("execution", {})
	if execution is Dictionary:
		return execution
	return {}

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

func _assert_execution_mutated_wall(plan: Dictionary, label: String) -> bool:
	var execution := _extract_execution(plan)
	var ok := true
	ok = _assert(bool(execution.get("ok", false)), "%s should complete successfully." % label) and ok
	ok = _assert(int(execution.get("ops_changed", 0)) > 0, "%s should report changed voxel operations." % label) and ok
	var changed_region: Dictionary = execution.get("changed_region", {})
	ok = _assert(bool(changed_region.get("valid", false)), "%s should provide a valid changed_region (changed tiles)." % label) and ok
	var region_min: Dictionary = changed_region.get("min", {})
	var region_max: Dictionary = changed_region.get("max", {})
	for key in ["x", "y", "z"]:
		ok = _assert(region_min.has(key), "%s changed_region.min should include '%s'." % [label, key]) and ok
		ok = _assert(region_max.has(key), "%s changed_region.max should include '%s'." % [label, key]) and ok
	var changed_chunks = execution.get("changed_chunks", [])
	ok = _assert(changed_chunks is Array, "%s should expose changed_chunks as an array." % label) and ok
	if changed_chunks is Array:
		ok = _assert((changed_chunks as Array).size() > 0, "%s should include at least one changed chunk." % label) and ok
	return ok

func _assert_execution_replay_stable(first_plan: Dictionary, second_plan: Dictionary, label: String) -> bool:
	var first_execution := _extract_execution(first_plan)
	var second_execution := _extract_execution(second_plan)
	var ok := true
	ok = _assert(
		int(first_execution.get("ops_changed", -1)) == int(second_execution.get("ops_changed", -2)),
		"%s should preserve ops_changed across replay." % label
	) and ok
	ok = _assert(
		first_execution.get("changed_region", {}) == second_execution.get("changed_region", {}),
		"%s should preserve changed_region payload across replay." % label
	) and ok
	ok = _assert(
		first_execution.get("changed_chunks", []) == second_execution.get("changed_chunks", []),
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
