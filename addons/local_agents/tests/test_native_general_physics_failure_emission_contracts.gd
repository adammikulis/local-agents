@tool
extends RefCounted

const NATIVE_FAILURE_EMISSION_PLANNER_CPP_PATH := "res://addons/local_agents/gdextensions/localagents/src/SimulationFailureEmissionPlanner.cpp"
const NATIVE_FAILURE_EMISSION_NOISE_CPP_PATH := "res://addons/local_agents/gdextensions/localagents/src/FailureEmissionDeterministicNoise.cpp"
const NATIVE_CORE_CPP_PATH := "res://addons/local_agents/gdextensions/localagents/src/LocalAgentsSimulationCore.cpp"

func run_test(_tree: SceneTree) -> bool:
	var planner_source := _read_source(NATIVE_FAILURE_EMISSION_PLANNER_CPP_PATH)
	if planner_source == "":
		return false
	var noise_source := _read_source(NATIVE_FAILURE_EMISSION_NOISE_CPP_PATH)
	if noise_source == "":
		return false
	var core_source := _read_source(NATIVE_CORE_CPP_PATH)
	if core_source == "":
		return false
	var ok := true
	ok = _test_directional_failure_cleave_contract(planner_source) and ok
	ok = _test_fallback_fracture_contract(planner_source) and ok
	ok = _test_environment_stage_driver_contract(planner_source, core_source) and ok
	ok = _test_noise_metadata_contract(planner_source, noise_source) and ok
	if ok:
		print("Native generalized physics failure emission contracts passed (directional cleave + fallback fracture source markers).")
	return ok

func _test_directional_failure_cleave_contract(source: String) -> bool:
	var ok := true
	ok = _assert(
		source.contains("op_payload[\"operation\"] = String(\"cleave\");") or source.contains("String(\"cleave\")"),
		"Directional impact emission contract must expose cleave operation payload marker."
	) and ok
	ok = _assert(
		source.contains("directionality") or source.contains("directional") or source.contains("impact_normal"),
		"Directional impact emission contract must evaluate directionality/impact vector signal."
	) and ok
	ok = _assert(
		source.contains("contact_projection.impact_signal") or source.contains("impact_signal"),
		"Directional impact emission contract must use impact signal for deterministic emission planning."
	) and ok
	return ok

func _test_fallback_fracture_contract(source: String) -> bool:
	var ok := true
	ok = _assert(source.contains("op_payload[\"operation\"] = String(\"fracture\");"), "Fallback emission contract must preserve fracture operation payload marker.") and ok
	ok = _assert(source.contains("op_payload[\"reason\"]"), "Emission payload contract must include deterministic reason field.") and ok
	ok = _assert(source.contains("op_payload[\"contact_signal\"]"), "Emission payload contract must include deterministic contact_signal field.") and ok
	ok = _assert(source.contains("op_payload[\"impact_work\"]"), "Emission payload contract must include deterministic impact_work field.") and ok
	return ok

func _test_environment_stage_driver_contract(planner_source: String, core_source: String) -> bool:
	var ok := true
	ok = _assert(planner_source.contains("plan[\"target_domain\"] = String(\"environment\");"), "Failure emission planner must route through environment target_domain.") and ok
	ok = _assert(planner_source.contains("plan[\"stage_name\"] = String(\"physics_failure_emission\");"), "Failure emission planner must route through physics_failure_emission stage.") and ok
	ok = _assert(
		core_source.contains("const String plan_target_domain = as_status_text(")
			and core_source.contains("voxel_failure_emission.get(\"target_domain\", String(\"environment\"))"),
		"Core environment-stage execution must use planner target_domain routing."
	) and ok
	ok = _assert(
		core_source.contains("const String plan_stage_name = as_status_text(")
			and core_source.contains("voxel_failure_emission.get(\"stage_name\", String(\"physics_failure_emission\"))"),
		"Core environment-stage execution must use planner stage_name routing."
	) and ok
	ok = _assert(
		not planner_source.contains("carve"),
		"Failure emission planner must not provide a local carve driver path."
	) and ok
	return ok

func _test_noise_metadata_contract(planner_source: String, noise_source: String) -> bool:
	var ok := true
	ok = _assert(
		planner_source.contains("write_deterministic_noise_fields(op_payload, noise_profile);"),
		"Emission payload contract must write deterministic noise metadata through helper on source path."
	) and ok
	ok = _assert(noise_source.contains("payload[\"noise_seed\"]"), "Emission payload contract must include deterministic noise_seed metadata marker.") and ok
	ok = _assert(noise_source.contains("payload[\"noise_frequency\"]"), "Emission payload contract must include deterministic noise_frequency metadata marker.") and ok
	ok = _assert(noise_source.contains("payload[\"noise_octaves\"]"), "Emission payload contract must include deterministic noise_octaves metadata marker.") and ok
	ok = _assert(noise_source.contains("payload[\"noise_lacunarity\"]"), "Emission payload contract must include deterministic noise_lacunarity metadata marker.") and ok
	ok = _assert(
		noise_source.contains("payload[\"noise_gain\"]") or noise_source.contains("payload[\"noise_persistence\"]"),
		"Emission payload contract must include deterministic fractal gain metadata marker."
	) and ok
	return ok

func _read_source(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		_assert(false, "Failed to open source: %s" % path)
		return ""
	return file.get_as_text()

func _assert(condition: bool, message: String) -> bool:
	if not condition:
		push_error(message)
	return condition
