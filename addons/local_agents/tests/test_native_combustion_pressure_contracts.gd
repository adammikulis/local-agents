@tool
extends RefCounted

const PIPELINE_CPP_PATH := "res://addons/local_agents/gdextensions/localagents/src/sim/UnifiedSimulationPipeline.cpp"
const INTERFACES_HPP_PATH := "res://addons/local_agents/gdextensions/localagents/include/LocalAgentsSimulationInterfaces.hpp"
const BRIDGE_GD_PATH := "res://addons/local_agents/simulation/controller/NativeComputeBridge.gd"

func run_test(_tree: SceneTree) -> bool:
	var ok := true
	ok = _test_native_interfaces_include_combustion_solver() and ok
	ok = _test_required_physics_channels_include_pressure() and ok
	ok = _test_combustion_stage_uses_pressure_and_temperature_gating() and ok
	ok = _test_bridge_builds_canonical_material_inputs() and ok
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
	var source := _read_source(PIPELINE_CPP_PATH)
	if source == "":
		return false
	var ok := true
	ok = _assert(source.contains("channels.append(String(\"pressure\"));"), "Required channels must include pressure") and ok
	ok = _assert(source.contains("channels.append(String(\"temperature\"));"), "Required channels must include temperature") and ok
	ok = _assert(source.contains("channels.append(String(\"density\"));"), "Required channels must include density") and ok
	ok = _assert(source.contains("summary[\"missing_channels\"] = missing_channels;"), "Pipeline must expose missing physics channels") and ok
	ok = _assert(source.contains("summary[\"physics_ready\"] = missing_channels.is_empty();"), "Pipeline must expose physics_ready readiness") and ok
	return ok

func _test_combustion_stage_uses_pressure_and_temperature_gating() -> bool:
	var source := _read_source(PIPELINE_CPP_PATH)
	if source == "":
		return false
	var ok := true
	ok = _assert(source.contains("Dictionary UnifiedSimulationPipeline::run_combustion_stage"), "Pipeline must define combustion stage runner") and ok
	ok = _assert(source.contains("const double ignition_temperature"), "Combustion stage must define ignition temperature") and ok
	ok = _assert(source.contains("const double min_pressure"), "Combustion stage must define min pressure") and ok
	ok = _assert(source.contains("const double max_pressure"), "Combustion stage must define max pressure") and ok
	ok = _assert(source.contains("const double optimal_pressure"), "Combustion stage must define optimal pressure") and ok
	ok = _assert(source.contains("const double pressure = clamped(frame_inputs.get(\"pressure\""), "Combustion stage must read pressure input") and ok
	ok = _assert(source.contains("const bool ignited = temperature >= ignition_temperature"), "Combustion stage must gate ignition by temperature") and ok
	ok = _assert(source.contains("const double pressure_factor = pressure_window_factor"), "Combustion stage must gate intensity by pressure factor") and ok
	ok = _assert(source.contains("result[\"heat_delta\"]"), "Combustion stage must output heat delta") and ok
	ok = _assert(source.contains("result[\"terrain_damage_budget\"]"), "Combustion stage must output terrain damage budget") and ok
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

func _assert(condition: bool, message: String) -> bool:
	if not condition:
		push_error(message)
	return condition

func _read_source(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		_assert(false, "Failed to open source: %s" % path)
		return ""
	return file.get_as_text()
