@tool
extends RefCounted

const CORE_HPP_PATH := "res://addons/local_agents/gdextensions/localagents/include/LocalAgentsSimulationCore.hpp"
const CORE_CPP_PATH := "res://addons/local_agents/gdextensions/localagents/src/LocalAgentsSimulationCore.cpp"
const ORCHESTRATION_HPP_PATH := "res://addons/local_agents/gdextensions/localagents/include/LocalAgentsVoxelOrchestration.hpp"
const ORCHESTRATION_CPP_PATH := "res://addons/local_agents/gdextensions/localagents/src/LocalAgentsVoxelOrchestration.cpp"

func run_test(_tree: SceneTree) -> bool:
	var header := _read_source(CORE_HPP_PATH)
	var source := _read_source(CORE_CPP_PATH)
	var orchestration_header := _read_source(ORCHESTRATION_HPP_PATH)
	var orchestration_source := _read_source(ORCHESTRATION_CPP_PATH)
	if header == "" or source == "" or orchestration_header == "" or orchestration_source == "":
		return false

	var ok := true
	ok = _assert(header.contains("configure_voxel_orchestration(const Dictionary &config"), "Core header must declare configure_voxel_orchestration.") and ok
	ok = _assert(header.contains("queue_projectile_contact_rows(const Array &contact_rows, int64_t frame_index)"), "Core header must declare queue_projectile_contact_rows.") and ok
	ok = _assert(header.contains("acknowledge_projectile_contact_rows(int64_t consumed_count, bool mutation_applied, int64_t frame_index)"), "Core header must declare acknowledge_projectile_contact_rows.") and ok
	ok = _assert(header.contains("execute_voxel_orchestration_tick("), "Core header must declare execute_voxel_orchestration_tick.") and ok
	ok = _assert(header.contains("get_voxel_orchestration_state() const"), "Core header must declare get_voxel_orchestration_state.") and ok
	ok = _assert(header.contains("get_voxel_orchestration_metrics() const"), "Core header must declare get_voxel_orchestration_metrics.") and ok
	ok = _assert(header.contains("void reset_voxel_orchestration()"), "Core header must declare reset_voxel_orchestration.") and ok

	for method_name in [
		"configure_voxel_orchestration",
		"queue_projectile_contact_rows",
		"acknowledge_projectile_contact_rows",
		"execute_voxel_orchestration_tick",
		"get_voxel_orchestration_state",
		"get_voxel_orchestration_metrics",
		"reset_voxel_orchestration",
	]:
		ok = _assert(
			source.contains("D_METHOD(\"%s\"" % method_name),
			"Core source must bind voxel orchestration method: %s" % method_name
		) and ok

	ok = _assert(orchestration_header.contains("class LocalAgentsVoxelOrchestration"), "Native orchestration helper class must exist.") and ok
	ok = _assert(orchestration_source.contains("PROJECTILE_MUTATION_DEADLINE_EXCEEDED"), "Native orchestration helper must classify projectile mutation deadline exceeded failures.") and ok
	ok = _assert(orchestration_source.contains("ticks_forced_contact_flush_"), "Native orchestration helper must own cadence/flush telemetry counters.") and ok
	ok = _assert(orchestration_source.contains("queue_projectile_contact_rows"), "Native orchestration helper must implement queue ingestion.") and ok
	ok = _assert(orchestration_source.contains("acknowledge_projectile_contact_rows"), "Native orchestration helper must implement queue acknowledgement.") and ok

	if ok:
		print("Native voxel orchestration contracts passed (core API bindings + native queue/deadline helper ownership).")
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
