@tool
extends RefCounted

const SIM_SOURCE_DIR := "res://addons/local_agents/gdextensions/localagents/src/sim"
const LEGACY_PIPELINE_CPP_PATH := "res://addons/local_agents/gdextensions/localagents/src/sim/CoreSimulationPipeline.cpp"
const INTERFACES_HPP_PATH := "res://addons/local_agents/gdextensions/localagents/include/LocalAgentsSimulationInterfaces.hpp"
const CORE_HPP_PATH := "res://addons/local_agents/gdextensions/localagents/include/LocalAgentsSimulationCore.hpp"
const CORE_CPP_PATH := "res://addons/local_agents/gdextensions/localagents/src/LocalAgentsSimulationCore.cpp"
const BRIDGE_GD_PATH := "res://addons/local_agents/simulation/controller/NativeComputeBridge.gd"
const NativeComputeBridgeScript := preload("res://addons/local_agents/simulation/controller/NativeComputeBridge.gd")

func run_test(_tree: SceneTree) -> bool:
	var ok := true
	ok = _test_native_interfaces_include_combustion_solver() and ok
	ok = _test_required_physics_channels_include_pressure() and ok
	ok = _test_combustion_stage_uses_pressure_and_temperature_gating() and ok
	ok = _test_bridge_builds_canonical_material_inputs() and ok
	ok = _test_environment_payload_normalization_supports_physics_contact_rows() and ok
	ok = _test_bridge_normalization_and_contact_aggregation_behavior() and ok
	ok = _test_environment_result_contract_shaping_behavior() and ok
	ok = _test_core_contact_ingestion_methods_are_bound_when_declared() and ok
	if ok:
		print("Native combustion pressure contracts passed (interfaces, channels, stage gating, bridge payload).")
	return ok

func _test_native_interfaces_include_combustion_solver() -> bool:
	var source := _read_source(INTERFACES_HPP_PATH)
	if source == "":
		return false
	var ok := true
	ok = _assert(source.contains("class ICombustionSolver"), "Native interfaces must define ICombustionSolver") and ok
	ok = _assert(source.contains("execute_stage(const godot::Dictionary &stage_config, const godot::Dictionary &stage_inputs)"), "ICombustionSolver must expose execute_stage contract") and ok
	return ok

func _test_required_physics_channels_include_pressure() -> bool:
	var source := _read_pipeline_sources()
	if source == "":
		return false
	var ok := true
	ok = _assert(source.contains("\"pressure\""), "Required channels must include pressure") and ok
	ok = _assert(source.contains("\"temperature\""), "Required channels must include temperature") and ok
	ok = _assert(source.contains("\"density\""), "Required channels must include density") and ok
	ok = _assert(source.contains("summary[\"missing_channels\"] = missing_channels;"), "Pipeline must expose missing physics channels") and ok
	ok = _assert(source.contains("summary[\"physics_ready\"] = missing_channels.is_empty();"), "Pipeline must expose physics_ready readiness") and ok
	return ok

func _test_combustion_stage_uses_pressure_and_temperature_gating() -> bool:
	var source := _read_pipeline_sources()
	if source == "":
		return false
	var ok := true
	ok = _assert(source.contains("Dictionary CoreSimulationPipeline::run_reaction_stage"), "Pipeline must define reaction stage runner for combustion-compatible chemistry") and ok
	ok = _assert(source.contains("const double activation_temperature"), "Reaction stage must define activation temperature") and ok
	ok = _assert(source.contains("const double min_pressure"), "Combustion stage must define min pressure") and ok
	ok = _assert(source.contains("const double max_pressure"), "Combustion stage must define max pressure") and ok
	ok = _assert(source.contains("const double optimal_pressure"), "Combustion stage must define optimal pressure") and ok
	ok = _assert(
		_contains_any(
			source,
			[
				"const double pressure = clamped(stage_field_inputs.get(\"pressure\"",
				"const double pressure = unified_pipeline::clamped(stage_field_inputs.get(\"pressure\"",
			]
		),
		"Combustion stage must read pressure input"
	) and ok
	ok = _assert(source.contains("temperature >= activation_temperature"), "Reaction stage must gate combustion-like chemistry by temperature activation") and ok
	ok = _assert(
		_contains_any(source, ["const double pressure_factor = pressure_window_factor", "const double pressure_factor = unified_pipeline::pressure_window_factor"]),
		"Combustion stage must gate intensity by pressure factor"
	) and ok
	ok = _assert(source.contains("\"heat_delta\""), "Combustion stage must output heat delta") and ok
	ok = _assert(source.contains("\"reaction_extent\""), "Reaction stage must expose reaction extent output") and ok
	return ok

func _test_bridge_builds_canonical_material_inputs() -> bool:
	var source := _read_source(BRIDGE_GD_PATH)
	if source == "":
		return false
	var ok := true
	ok = _assert(source.contains("const _CANONICAL_INPUT_KEYS"), "Bridge must define canonical material input keys") and ok
	ok = _assert(source.contains("static func _normalize_environment_payload(payload: Dictionary) -> Dictionary:"), "Bridge must normalize environment payload") and ok
	ok = _assert(source.contains("normalized[\"inputs\"] = inputs"), "Bridge must inject normalized inputs payload") and ok
	ok = _assert(source.contains("if not out.has(\"pressure\")"), "Bridge must default pressure when missing") and ok
	return ok

func _test_environment_payload_normalization_supports_physics_contact_rows() -> bool:
	var source := _read_source(BRIDGE_GD_PATH)
	if source == "":
		return false
	var ok := true
	ok = _assert(source.contains("static func _normalize_environment_payload(payload: Dictionary) -> Dictionary:"), "Bridge must normalize environment payload before stage dispatch") and ok
	ok = _assert(
		_contains_any(
			source,
			["_merge_physics_contact_inputs(", "_normalize_physics_contacts_from_payload("]
		),
		"Bridge normalization must include a dedicated physics-contact merge path"
	) and ok
	ok = _assert(
		_contains_any(
			source,
			[
				"payload.get(\"physics_contacts\"",
				"payload.get(\"contact_samples\"",
				"payload.get(\"physics_server_contacts\"",
				"for key in [\"physics_server_contacts\", \"physics_contacts\", \"contact_samples\"]",
			]
		),
		"Bridge normalization must accept physics contact row payloads"
	) and ok
	ok = _assert(
		_contains_any(
			source,
			[
				"out[\"contact_impulse\"]",
				"inputs[\"contact_impulse\"]",
			]
		),
		"Bridge must map aggregate contact influence into canonical contact_impulse input"
	) and ok
	ok = _assert(
		_contains_any(
			source,
			[
				"out[\"contact_normal\"]",
				"inputs[\"contact_normal\"]",
			]
		),
		"Bridge must map aggregate contact influence into canonical contact_normal input"
	) and ok
	ok = _assert(
		_contains_any(
			source,
			[
				"out[\"contact_point\"]",
				"inputs[\"contact_point\"]",
			]
		),
		"Bridge must map aggregate contact influence into canonical contact_point input"
	) and ok
	ok = _assert(
		_contains_any(
			source,
			[
				"out[\"body_velocity\"]",
				"inputs[\"body_velocity\"]",
			]
		),
		"Bridge must map aggregate contact influence into canonical body_velocity input"
	) and ok
	ok = _assert(
		_contains_any(
			source,
			[
				"out[\"body_id\"]",
				"inputs[\"body_id\"]",
			]
		),
		"Bridge must map aggregate contact influence into canonical body_id input"
	) and ok
	ok = _assert(
		_contains_any(
			source,
			[
				"out[\"rigid_obstacle_mask\"]",
				"inputs[\"rigid_obstacle_mask\"]",
			]
		),
		"Bridge must map aggregate contact influence into canonical rigid_obstacle_mask input"
	) and ok
	return ok

func _test_bridge_normalization_and_contact_aggregation_behavior() -> bool:
	var payload := {
		"pressure_atm": 1.5,
		"physics_contacts": [
			{
				"id": 9,
				"collision_mask": 5,
				"normal_impulse": 4.0,
				"collision_normal": Vector3(0.0, 3.0, 0.0),
				"collision_point": [1.0, 2.0, 3.0],
				"velocity": Vector3(3.0, 4.0, 0.0),
				"motion_speed": 12.0,
			},
			{
				"body_id": 3,
				"rigid_obstacle_mask": 2,
				"contact_impulse": 6.0,
				"contact_normal": {"x": 1.0, "y": 0.0, "z": 0.0},
				"contact_point": Vector3(4.0, 2.0, 3.0),
				"body_velocity": 6.0,
				"obstacle_velocity": 2.0,
			},
		],
	}
	var normalized: Dictionary = NativeComputeBridgeScript._normalize_environment_payload(payload)
	var contacts_variant = normalized.get("physics_server_contacts", [])
	var contacts: Array = contacts_variant if contacts_variant is Array else []
	var inputs_variant = normalized.get("inputs", {})
	var inputs: Dictionary = inputs_variant if inputs_variant is Dictionary else {}
	var ok := true
	ok = _assert(contacts.size() == 2, "Bridge normalization should preserve both physics contacts after canonicalization.") and ok
	ok = _assert(_is_approx(float(inputs.get("contact_impulse", 0.0)), 20.0), "Bridge aggregation should sum canonicalized contact rows used by native wrapper aggregation.") and ok
	ok = _assert(_is_approx(float(inputs.get("contact_velocity", 0.0)), 5.2), "Bridge aggregation should compute weighted contact velocity average.") and ok
	ok = _assert(_is_approx(float(inputs.get("body_velocity", 0.0)), 5.6), "Bridge aggregation should compute weighted body_velocity average.") and ok
	ok = _assert(_is_approx(float(inputs.get("obstacle_velocity", 0.0)), 6.0), "Bridge aggregation should compute weighted obstacle_velocity average.") and ok
	ok = _assert(int(inputs.get("body_id", -1)) == 3, "Bridge aggregation should use strongest-impulse body_id as canonical authority row.") and ok
	ok = _assert(int(inputs.get("rigid_obstacle_mask", 0)) == 2, "Bridge aggregation should use strongest-impulse rigid_obstacle_mask.") and ok
	ok = _assert(_is_approx(float(inputs.get("pressure", 0.0)), 151987.5), "Bridge normalization should canonicalize pressure aliases into native pressure units.") and ok
	var contact_normal_variant = inputs.get("contact_normal", Vector3.ZERO)
	ok = _assert(contact_normal_variant is Vector3, "Bridge aggregation should shape contact_normal as Vector3.") and ok
	if contact_normal_variant is Vector3:
		var contact_normal := contact_normal_variant as Vector3
		ok = _assert(absf(contact_normal.length() - 1.0) <= 1.0e-4, "Bridge aggregation should normalize aggregated contact_normal.") and ok
		ok = _assert(contact_normal.x > 0.8 and contact_normal.y > 0.5, "Bridge aggregation should preserve weighted normal direction from authoritative rows.") and ok
	return ok

func _test_environment_result_contract_shaping_behavior() -> bool:
	var normalized: Dictionary = NativeComputeBridgeScript._normalize_environment_stage_result({
		"ok": false,
		"error": "gpu_backend_unavailable",
		"execution": {"dispatched": true},
		"result_fields": {
			"inputs": {
				"material_id": "ore:iron",
				"phase": "gas",
			},
		},
	})
	var result_fields_variant = normalized.get("result_fields", {})
	var result_fields: Dictionary = result_fields_variant if result_fields_variant is Dictionary else {}
	var inputs_variant = result_fields.get("inputs", {})
	var inputs: Dictionary = inputs_variant if inputs_variant is Dictionary else {}
	var identity_variant = result_fields.get("material_identity", {})
	var identity: Dictionary = identity_variant if identity_variant is Dictionary else {}
	var ok := true
	ok = _assert(not bool(normalized.get("ok", true)), "Wrapper contract shaping should preserve failed native status.") and ok
	ok = _assert(String(normalized.get("error", "")) == "gpu_unavailable", "Wrapper contract shaping should preserve typed fail-fast gpu_unavailable error.") and ok
	ok = _assert(bool(normalized.get("executed", false)), "Wrapper contract shaping should report executed=true for native result envelopes.") and ok
	ok = _assert(bool(normalized.get("dispatched", false)), "Wrapper contract shaping should forward execution.dispatched metadata.") and ok
	ok = _assert(String(inputs.get("material_id", "")) == "ore:iron", "Wrapper contract shaping should preserve material_id in normalized inputs.") and ok
	ok = _assert(String(inputs.get("material_phase_id", "")) == "phase:gas", "Wrapper contract shaping should canonicalize material_phase_id from phase inputs.") and ok
	ok = _assert(String(identity.get("material_phase_id", "")) == "phase:gas", "Wrapper contract shaping should include canonicalized material identity fields.") and ok
	return ok

func _test_core_contact_ingestion_methods_are_bound_when_declared() -> bool:
	var header := _read_source(CORE_HPP_PATH)
	if header == "":
		return false
	var source := _read_source(CORE_CPP_PATH)
	if source == "":
		return false

	var declarations := {
		"ingest_physics_contacts": "ingest_physics_contacts(const Array &contact_rows)",
		"clear_physics_contacts": "clear_physics_contacts()",
		"get_physics_contact_snapshot": "get_physics_contact_snapshot() const",
	}
	var ok := true
	for method_name_variant in declarations.keys():
		var method_name := String(method_name_variant)
		var declaration := String(declarations.get(method_name, ""))
		if not header.contains(declaration):
			continue
		ok = _assert(
			source.contains("ClassDB::bind_method(D_METHOD(\"%s\"" % method_name),
			"LocalAgentsSimulationCore must bind declared contact ingestion method: %s" % method_name
		) and ok
	return ok

func _contains_any(source: String, needles: Array[String]) -> bool:
	for needle in needles:
		if source.contains(needle):
			return true
	return false

func _assert(condition: bool, message: String) -> bool:
	if not condition:
		push_error(message)
	return condition

func _is_approx(lhs: float, rhs: float, epsilon: float = 1.0e-4) -> bool:
	return absf(lhs - rhs) <= epsilon

func _read_pipeline_sources() -> String:
	var files := _list_sim_source_files()
	if files.is_empty():
		return ""

	var combined := PackedStringArray()
	for path in files:
		var source := _read_source(path)
		if source == "":
			return ""
		combined.append("// file: %s\n%s" % [path, source])
	return "\n".join(combined)

func _list_sim_source_files() -> PackedStringArray:
	var files := PackedStringArray()
	var sim_dir := DirAccess.open(SIM_SOURCE_DIR)
	if sim_dir == null:
		_assert(false, "Failed to open sim source dir: %s" % SIM_SOURCE_DIR)
		files.append(LEGACY_PIPELINE_CPP_PATH)
		return files

	sim_dir.list_dir_begin()
	var entry := sim_dir.get_next()
	while entry != "":
		if not sim_dir.current_is_dir() and (entry.ends_with(".cpp") or entry.ends_with(".hpp")):
			files.append("%s/%s" % [SIM_SOURCE_DIR, entry])
		entry = sim_dir.get_next()
	sim_dir.list_dir_end()

	files.sort()
	if files.is_empty():
		files.append(LEGACY_PIPELINE_CPP_PATH)
	return files

func _read_source(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		_assert(false, "Failed to open source: %s" % path)
		return ""
	return file.get_as_text()
