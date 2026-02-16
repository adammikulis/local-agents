@tool
extends RefCounted

const SIM_SOURCE_DIR := "res://addons/local_agents/gdextensions/localagents/src/sim"
const LEGACY_PIPELINE_CPP_PATH := "res://addons/local_agents/gdextensions/localagents/src/sim/CoreSimulationPipeline.cpp"
const INTERFACES_HPP_PATH := "res://addons/local_agents/gdextensions/localagents/include/LocalAgentsSimulationInterfaces.hpp"
const CORE_HPP_PATH := "res://addons/local_agents/gdextensions/localagents/include/LocalAgentsSimulationCore.hpp"
const CORE_CPP_PATH := "res://addons/local_agents/gdextensions/localagents/src/LocalAgentsSimulationCore.cpp"
const BRIDGE_GD_PATH := "res://addons/local_agents/simulation/controller/NativeComputeBridge.gd"
const NativeComputeBridgeScript := preload("res://addons/local_agents/simulation/controller/NativeComputeBridge.gd")
const NativeComputeBridgeEnvironmentBindingsScript := preload("res://addons/local_agents/simulation/controller/NativeComputeBridgeEnvironmentBindings.gd")

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
	var normalized: Dictionary = NativeComputeBridgeScript._normalize_environment_payload({
		"material_id": "ore:copper",
		"phase": "gas",
		"inputs": {
			"element_id": "element:cu",
		},
	})
	var identity_variant = normalized.get("material_identity", {})
	var identity: Dictionary = identity_variant if identity_variant is Dictionary else {}
	var inputs_variant = normalized.get("inputs", {})
	var inputs: Dictionary = inputs_variant if inputs_variant is Dictionary else {}
	var ok := true
	ok = _assert(String(identity.get("material_id", "")) == "ore:copper", "Bridge must preserve material_id in normalized material_identity.") and ok
	ok = _assert(String(identity.get("material_phase_id", "")) == "phase:gas", "Bridge must canonicalize phase into material_phase_id.") and ok
	ok = _assert(String(inputs.get("material_phase_id", "")) == "phase:gas", "Bridge must inject canonicalized material_phase_id into normalized inputs.") and ok
	ok = _assert(String(inputs.get("element_id", "")) == "element:cu", "Bridge must preserve explicit element_id through normalization.") and ok
	return ok

func _test_environment_payload_normalization_supports_physics_contact_rows() -> bool:
	var normalized: Dictionary = NativeComputeBridgeScript._normalize_environment_payload({
		"contact_samples": [
			{"id": 9, "normal_impulse": 4.0},
			{"body_id": 3, "contact_impulse": 6.0},
		],
	})
	var contacts_variant = normalized.get("physics_server_contacts", [])
	var contacts: Array = contacts_variant if contacts_variant is Array else []
	var mirrored_variant = normalized.get("physics_contacts", [])
	var mirrored: Array = mirrored_variant if mirrored_variant is Array else []
	var inputs_variant = normalized.get("inputs", {})
	var inputs: Dictionary = inputs_variant if inputs_variant is Dictionary else {}
	var ok := true
	ok = _assert(contacts.size() == 2, "Bridge normalization must accept and preserve physics contact row payloads.") and ok
	ok = _assert(mirrored.size() == 2, "Bridge normalization must mirror preserved contact rows on physics_contacts.") and ok
	ok = _assert(not inputs.has("contact_impulse"), "Bridge normalization should defer aggregate contact inputs until native snapshot is applied.") and ok
	return ok

func _test_bridge_normalization_and_contact_aggregation_behavior() -> bool:
	var normalized: Dictionary = NativeComputeBridgeScript._normalize_environment_payload({
		"pressure_atm": 1.5,
		"physics_contacts": [
			{"id": 9, "normal_impulse": 4.0},
			{"body_id": 3, "contact_impulse": 6.0},
		],
	})
	var bound: Dictionary = NativeComputeBridgeEnvironmentBindingsScript.apply_native_contact_snapshot(
		normalized,
		{
			"total_impulse": 20.0,
			"average_relative_speed": 5.2,
			"buffered_rows": [
				{"id": 9, "normal_impulse": 4.0},
				{"body_id": 3, "contact_impulse": 6.0},
			],
		}
	)
	var contacts_variant = bound.get("physics_server_contacts", [])
	var contacts: Array = contacts_variant if contacts_variant is Array else []
	var inputs_variant = bound.get("inputs", {})
	var inputs: Dictionary = inputs_variant if inputs_variant is Dictionary else {}
	var snapshot_variant = bound.get("physics_contacts", {})
	var snapshot: Dictionary = snapshot_variant if snapshot_variant is Dictionary else {}
	var ok := true
	ok = _assert(contacts.size() == 2, "Bridge snapshot binding should surface native buffered rows on physics_server_contacts.") and ok
	ok = _assert(_is_approx(float(inputs.get("contact_impulse", 0.0)), 20.0), "Bridge should bind native snapshot total_impulse into canonical contact_impulse input.") and ok
	ok = _assert(_is_approx(float(inputs.get("contact_velocity", 0.0)), 5.2), "Bridge should bind native snapshot average_relative_speed into canonical contact_velocity input.") and ok
	ok = _assert(snapshot.get("buffered_rows", []) is Array and int((snapshot.get("buffered_rows", []) as Array).size()) == 2, "Bridge should preserve native snapshot payload on physics_contacts.") and ok
	ok = _assert(not inputs.has("pressure"), "Bridge normalization should not pre-canonicalize pressure aliases before native environment-stage execution.") and ok
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
