@tool
extends RefCounted

const ExtensionLoader := preload("res://addons/local_agents/runtime/LocalAgentsExtensionLoader.gd")
const ContactNormalizationScript := preload("res://addons/local_agents/simulation/controller/NativeComputeBridgeContactNormalization.gd")
const CONTACT_NORMALIZATION_GD_PATH := "res://addons/local_agents/simulation/controller/NativeComputeBridgeContactNormalization.gd"
const NATIVE_COMPUTE_BRIDGE_GD_PATH := "res://addons/local_agents/simulation/controller/NativeComputeBridge.gd"

func run_test(_tree: SceneTree) -> bool:
	if not ExtensionLoader.ensure_initialized():
		push_error("LocalAgentsExtensionLoader failed to initialize for native contact serializer contract test: %s" % ExtensionLoader.get_error())
		return false
	if not Engine.has_singleton("LocalAgentsSimulationCore"):
		push_error("LocalAgentsSimulationCore singleton unavailable for native contact serializer contract test.")
		return false
	var core = Engine.get_singleton("LocalAgentsSimulationCore")
	if core == null:
		push_error("LocalAgentsSimulationCore singleton was null for native contact serializer contract test.")
		return false

	var ok := true
	ok = _test_native_serializer_normalizes_and_dedupes(core) and ok
	ok = _test_gds_wrapper_forwards_native_serializer_output() and ok
	ok = _test_serializer_contract_failure_is_not_silent_source() and ok
	if ok:
		print("Native contact serializer + GDS wrapper contract tests passed.")
	return ok

func _test_native_serializer_normalizes_and_dedupes(core: Object) -> bool:
	var rows := [
		{
			"body_id": 22,
			"collider_id": 900,
			"contact_id": "hit-A",
			"frame": 10,
			"contact_source": "fracture_dynamic",
			"contact_impulse": 6.0,
			"contact_velocity": 9.0,
			"body_mass": 0.2,
			"projectile_kind": "voxel_chunk",
			"projectile_density_tag": "dense",
			"projectile_hardness_tag": "hard",
			"projectile_material_tag": "dense_voxel",
			"failure_emission_profile": "dense_hard_voxel_chunk",
			"projectile_radius": 0.07,
			"deadline_frame": 36,
		},
		{
			"body_id": 22,
			"collider_id": 900,
			"contact_id": "hit-A",
			"frame": 10,
			"contact_source": "fracture_debris",
			"contact_impulse": 6.0,
			"contact_velocity": 9.0,
			"body_mass": 0.2,
			"projectile_kind": "voxel_chunk",
			"projectile_density_tag": "dense",
			"projectile_hardness_tag": "hard",
			"projectile_material_tag": "dense_voxel",
			"failure_emission_profile": "dense_hard_voxel_chunk",
			"projectile_radius": 0.07,
			"deadline_frame": 36,
		},
		{
			"body_id": 31,
			"collider_id": 901,
			"contact_id": "hit-B",
			"frame": 10,
			"contact_impulse": 4.0,
			"contact_velocity": 5.0,
			"body_mass": 0.4,
			"collider_mass": 0.6,
			"projectile_kind": "voxel_chunk",
			"projectile_density_tag": "dense",
			"projectile_hardness_tag": "hard",
			"projectile_material_tag": "dense_voxel",
			"failure_emission_profile": "dense_hard_voxel_chunk",
			"projectile_radius": 0.07,
			"deadline_frame": 37,
		}
	]

	var result_variant = core.call("normalize_and_aggregate_physics_contacts", rows)
	var result: Dictionary = result_variant if result_variant is Dictionary else {}
	var normalized_variant = result.get("normalized_rows", [])
	var normalized_rows: Array = normalized_variant if normalized_variant is Array else []
	var aggregate_variant = result.get("aggregated_inputs", {})
	var aggregate: Dictionary = aggregate_variant if aggregate_variant is Dictionary else {}

	var ok := true
	ok = _assert(bool(result.get("ok", false)), "Native serializer should return ok=true for valid contact rows.") and ok
	ok = _assert(normalized_rows.size() == 2, "Native serializer should dedupe duplicate contact rows using canonical native key fields.") and ok
	ok = _assert(int(result.get("row_count", -1)) == 2, "Native serializer row_count should reflect deduped row count.") and ok
	ok = _assert(_is_approx(float(aggregate.get("contact_impulse", 0.0)), 10.0), "Native aggregate contact_impulse should sum deduped impulses.") and ok
	ok = _assert(int(aggregate.get("body_id", -1)) == 22, "Native aggregate should preserve strongest-impulse body_id.") and ok
	if normalized_rows.size() >= 1 and normalized_rows[0] is Dictionary:
		var row := normalized_rows[0] as Dictionary
		ok = _assert(String(row.get("contact_source", "")).begins_with("fracture_"), "Native serializer should preserve contact_source metadata for failure emission routing.") and ok
		ok = _assert(String(row.get("projectile_kind", "")) == "voxel_chunk", "Native serializer should preserve projectile_kind metadata for voxel-on-voxel damage contracts.") and ok
		ok = _assert(String(row.get("failure_emission_profile", "")) == "dense_hard_voxel_chunk", "Native serializer should preserve failure_emission_profile metadata.") and ok
		ok = _assert(int(row.get("deadline_frame", -1)) >= 36, "Native serializer should preserve deadline_frame metadata for mutation deadline handling.") and ok
	return ok

func _test_gds_wrapper_forwards_native_serializer_output() -> bool:
	var payload := {
		"contact_samples": [
			{
				"body_id": 70,
				"collider_id": 710,
				"contact_id": "forward-hit",
				"frame": 99,
				"contact_impulse": 5.0,
				"contact_velocity": 8.0,
				"projectile_kind": "voxel_chunk",
				"projectile_density_tag": "dense",
				"projectile_hardness_tag": "hard",
				"projectile_material_tag": "dense_voxel",
				"failure_emission_profile": "dense_hard_voxel_chunk",
				"projectile_radius": 0.07,
				"deadline_frame": 125,
			},
			{
				"body_id": 70,
				"collider_id": 710,
				"contact_id": "forward-hit",
				"frame": 99,
				"contact_impulse": 5.0,
				"contact_velocity": 8.0,
				"projectile_kind": "voxel_chunk",
				"projectile_density_tag": "dense",
				"projectile_hardness_tag": "hard",
				"projectile_material_tag": "dense_voxel",
				"failure_emission_profile": "dense_hard_voxel_chunk",
				"projectile_radius": 0.07,
				"deadline_frame": 125,
			}
		]
	}
	var rows := ContactNormalizationScript.normalize_physics_contacts_from_payload(payload)
	var contract := ContactNormalizationScript.normalize_physics_contacts_contract(payload)
	var aggregate := ContactNormalizationScript.aggregate_contact_inputs(rows)
	var single := ContactNormalizationScript.normalize_contact_row((payload["contact_samples"] as Array)[0] as Dictionary)

	var ok := true
	ok = _assert(rows.size() == 1, "GDS contact normalization wrapper should forward native dedupe behavior.") and ok
	ok = _assert(bool(contract.get("ok", false)), "GDS contact normalization contract should report ok=true for valid contact rows.") and ok
	ok = _assert(int(contract.get("row_count", -1)) == 1, "GDS contact normalization contract should report deduped row_count.") and ok
	ok = _assert(_is_approx(float(aggregate.get("contact_impulse", 0.0)), 5.0), "GDS wrapper aggregate should match native serializer aggregate values.") and ok
	ok = _assert(int(aggregate.get("body_id", -1)) == 70, "GDS wrapper aggregate should preserve native strongest body_id.") and ok
	ok = _assert(String(single.get("projectile_kind", "")) == "voxel_chunk", "GDS wrapper normalize_contact_row should preserve native projectile_kind metadata.") and ok
	ok = _assert(int(single.get("rigid_obstacle_mask", -1)) == 0, "GDS wrapper normalize_contact_row should preserve native typed default rigid_obstacle_mask=0.") and ok
	ok = _assert(int(single.get("body_id", -1)) == 70, "GDS wrapper normalize_contact_row should preserve native typed body_id.") and ok
	return ok

func _test_serializer_contract_failure_is_not_silent_source() -> bool:
	var normalization_source := _read_script_source(CONTACT_NORMALIZATION_GD_PATH)
	if normalization_source == "":
		return false
	var native_bridge_source := _read_script_source(NATIVE_COMPUTE_BRIDGE_GD_PATH)
	if native_bridge_source == "":
		return false
	var ok := true
	ok = _assert(normalization_source.contains("static func normalize_physics_contacts_contract(payload: Dictionary) -> Dictionary:"), "Contact normalization wrapper must expose serializer contract output for runtime abort handling.") and ok
	ok = _assert(normalization_source.contains("push_error(\"NATIVE_REQUIRED: %s\" % error_code)"), "Contact normalization wrapper must emit typed NATIVE_REQUIRED error on serializer failure.") and ok
	ok = _assert(native_bridge_source.contains("if bool(normalized_payload.get(\"_abort_native_dispatch\", false)):"), "Native bridge must abort dispatch when contact serializer contract fails.") and ok
	ok = _assert(native_bridge_source.contains("\"native_contact_serializer_error\""), "Native bridge must preserve typed serializer error field on abort payload.") and ok
	return ok

func _assert(condition: bool, message: String) -> bool:
	if not condition:
		push_error(message)
	return condition

func _is_approx(lhs: float, rhs: float, epsilon: float = 1.0e-5) -> bool:
	return absf(lhs - rhs) <= epsilon

func _read_script_source(path: String) -> String:
	var source := FileAccess.get_file_as_string(path)
	if source == "":
		push_error("Failed to read source for contract assertion: %s" % path)
	return source
