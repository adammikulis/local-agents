@tool
extends RefCounted

const SIM_SOURCE_DIR := "res://addons/local_agents/gdextensions/localagents/src/sim"
const LEGACY_PIPELINE_CPP_PATH := "res://addons/local_agents/gdextensions/localagents/src/sim/CoreSimulationPipeline.cpp"
const INTERFACES_HPP_PATH := "res://addons/local_agents/gdextensions/localagents/include/LocalAgentsSimulationInterfaces.hpp"
const CORE_HPP_PATH := "res://addons/local_agents/gdextensions/localagents/include/LocalAgentsSimulationCore.hpp"
const CORE_CPP_PATH := "res://addons/local_agents/gdextensions/localagents/src/LocalAgentsSimulationCore.cpp"
const BRIDGE_GD_PATH := "res://addons/local_agents/simulation/controller/NativeComputeBridge.gd"

func run_test(_tree: SceneTree) -> bool:
	var ok := true
	ok = _test_native_interfaces_include_combustion_solver() and ok
	ok = _test_required_physics_channels_include_pressure() and ok
	ok = _test_combustion_stage_uses_pressure_and_temperature_gating() and ok
	ok = _test_bridge_builds_canonical_material_inputs() and ok
	ok = _test_environment_payload_normalization_supports_physics_contact_rows() and ok
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
