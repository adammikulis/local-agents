@tool
extends RefCounted

const INTERNAL_CPP_PATH := "res://addons/local_agents/gdextensions/localagents/src/sim/UnifiedSimulationPipelineInternal.cpp"

func run_test(_tree: SceneTree) -> bool:
	var ok := true
	ok = _test_field_buffer_drifts_are_clamped() and ok
	if ok:
		print("Native generalized physics Wave A invariants passed (field-buffer drift bounding and coupling-source checks).")
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
