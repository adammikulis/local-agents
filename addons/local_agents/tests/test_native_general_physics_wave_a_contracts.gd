@tool
extends RefCounted

const INTERNAL_CPP_PATH := "res://addons/local_agents/gdextensions/localagents/src/sim/UnifiedSimulationPipelineInternal.cpp"
const PIPELINE_CPP_PATH := "res://addons/local_agents/gdextensions/localagents/src/sim/UnifiedSimulationPipeline.cpp"
const PIPELINE_HPP_PATH := "res://addons/local_agents/gdextensions/localagents/include/sim/UnifiedSimulationPipeline.hpp"

func run_test(_tree: SceneTree) -> bool:
	var ok := true
	ok = _test_field_buffer_drifts_are_clamped() and ok
	ok = _test_execute_step_continuity_contracts() and ok
	if ok:
		print("Native generalized physics Wave A invariants passed (field-buffer drift bounding and coupling-source checks).")
	return ok

func _test_execute_step_continuity_contracts() -> bool:
	var internal_source := _read_source(INTERNAL_CPP_PATH)
	if internal_source == "":
		return false
	var pipeline_source := _read_source(PIPELINE_CPP_PATH)
	if pipeline_source == "":
		return false
	var pipeline_header := _read_source(PIPELINE_HPP_PATH)
	if pipeline_header == "":
		return false

	var ok := true
	ok = _assert(
		pipeline_source.contains("Dictionary build_field_buffer_input_patch"),
		"Wave A continuity should include helper to build carried field-buffer patches from field_evolution."
	) and ok
	ok = _assert(
		pipeline_source.contains("Dictionary merge_field_inputs_for_next_step"),
		"Wave A continuity should include merge logic for carried inputs across execute_step calls."
	) and ok
	ok = _assert(
		pipeline_source.contains("const Dictionary frame_inputs = merge_field_inputs_for_next_step"),
		"Wave A execute_step should merge carried field inputs before scheduling field evolution."
	) and ok
	ok = _assert(
		pipeline_source.contains("const Dictionary field_input_patch = build_field_buffer_input_patch(field_evolution)"),
		"Wave A execute_step should build a carried patch from updated field buffers."
	) and ok
	ok = _assert(
		pipeline_source.contains("if (!field_input_patch.is_empty())") and pipeline_source.contains("carried_field_inputs_ = field_input_patch;"),
		"Wave A continuity should persist updated field buffers for the next step."
	) and ok
	ok = _assert(
		pipeline_source.contains("carried_field_inputs_.clear();") and pipeline_header.contains("carried_field_inputs_"),
		"Wave A continuity state should reset carried inputs on configure and reset."
	) and ok
	return ok

func _test_field_buffer_drifts_are_clamped() -> bool:
	var internal_source := _read_source(INTERNAL_CPP_PATH)
	if internal_source == "":
		return false

	var ok := true
	ok = _assert(
		_contains_any(
			internal_source,
			[
				"const double mass_drift_proxy = clamped(mass_after - mass_before, -1.0e18, 1.0e18, 0.0);",
				"const double mass_drift_proxy = clamped(mass_after - mass_before, -1e18, 1e18, 0.0);"
			]
		),
		"Field evolution must clamp mass_drift_proxy with bounded envelopes."
	) and ok
	ok = _assert(
		_contains_any(
			internal_source,
			[
				"const double energy_drift_proxy = clamped(energy_after - energy_before, -1.0e18, 1.0e18, 0.0);",
				"const double energy_drift_proxy = clamped(energy_after - energy_before, -1e18, 1e18, 0.0);"
			]
		),
		"Field evolution must clamp energy_drift_proxy with bounded envelopes."
	) and ok
	ok = _assert(
		_contains_any(
			internal_source,
			["\"mass_drift_proxy\", mass_drift_proxy"]
		),
		"Field evolution result should expose bounded mass_drift_proxy field."
	) and ok
	ok = _assert(
		_contains_any(
			internal_source,
			["\"energy_drift_proxy\", energy_drift_proxy"]
		),
		"Field evolution result should expose bounded energy_drift_proxy field."
	) and ok
	return ok

func _assert(condition: bool, message: String) -> bool:
	if not condition:
		push_error(message)
	return condition

func _contains_any(source: String, needles: Array[String]) -> bool:
	for needle in needles:
		if source.contains(needle):
			return true
	return false

func _read_source(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		_assert(false, "Failed to open source: %s" % path)
		return ""
	return file.get_as_text()
