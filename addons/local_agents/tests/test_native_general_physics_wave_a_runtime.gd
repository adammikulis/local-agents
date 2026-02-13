@tool
extends RefCounted

const ExtensionLoader := preload("res://addons/local_agents/runtime/LocalAgentsExtensionLoader.gd")
const PIPELINE_STAGE_NAME := "wave_a_continuity"

const BASE_MASS := [1.0, 2.0]
const BASE_PRESSURE := [100.0, 110.0]
const BASE_TEMPERATURE := [300.0, 320.0]
const BASE_VELOCITY := [0.0, 1.0]
const BASE_DENSITY := [1.0, 2.0]
const BASE_TOPOLOGY := [[1], [0]]

func run_test(_tree: SceneTree) -> bool:
	if not ExtensionLoader.ensure_initialized():
		push_error("LocalAgentsExtensionLoader failed to initialize: %s" % ExtensionLoader.get_error())
		return false
	if not Engine.has_singleton("LocalAgentsSimulationCore"):
		push_error("LocalAgentsSimulationCore singleton unavailable for Wave-A continuity test.")
		return false

	var core := Engine.get_singleton("LocalAgentsSimulationCore")
	if core == null:
		push_error("LocalAgentsSimulationCore singleton was null.")
		return false

	if not _assert(bool(core.call("configure", {})), "LocalAgentsSimulationCore.configure() must succeed for test setup."):
		return false
	core.call("reset")

	var first_payload := _build_payload()
	var second_payload := first_payload.duplicate(true)
	var first_result: Dictionary = core.call("execute_environment_stage", PIPELINE_STAGE_NAME, first_payload)
	var second_result: Dictionary = core.call("execute_environment_stage", PIPELINE_STAGE_NAME, second_payload)

	var first_mass := _extract_updated_mass(first_result)
	var second_mass := _extract_updated_mass(second_result)
	var override_payload := _build_override_payload()
	var third_result: Dictionary = core.call("execute_environment_stage", PIPELINE_STAGE_NAME, override_payload)
	var third_mass := _extract_updated_mass(third_result)
	core.call("reset")
	var reset_result: Dictionary = core.call("execute_environment_stage", PIPELINE_STAGE_NAME, _build_payload())
	var reset_mass := _extract_updated_mass(reset_result)
	if not _assert(first_mass.size() == BASE_MASS.size(), "First step must emit mass update arrays."):
		return false
	if not _assert(second_mass.size() == BASE_MASS.size(), "Second step must emit mass update arrays."):
		return false
	if not _assert(third_mass.size() == BASE_MASS.size(), "Third step with explicit field_buffers override must emit mass update arrays."):
		return false

	var ok := true
	ok = _assert(not _arrays_equal(first_mass, second_mass), "Second execute_step must consume prior step updated fields, not restart from the unchanged input snapshot.") and ok
	ok = _assert(not _arrays_equal(first_mass, BASE_MASS), "First execute_step should evolve mass fields from its initial snapshot.") and ok
	ok = _assert(not _arrays_equal(second_mass, BASE_MASS), "Second execute_step should also evolve from prior fields, not initial mass snapshot.") and ok
	ok = _assert(not _arrays_equal(first_mass, third_mass), "Third execute_step should reflect explicit `field_buffers` override inputs.") and ok
	ok = _assert(third_mass[0] > 0.0, "Third execute_step result should be valid with explicit field buffer override input.") and ok
	ok = _assert(not _arrays_equal(third_mass, reset_mass), "Reset should clear carried continuity so subsequent execution reuses input snapshot baseline.") and ok

	if ok:
		print("Wave-A continuity runtime test passed for two-step field-buffer carry.")
	return ok

func _build_payload() -> Dictionary:
	return {
		"delta": 1.0,
		"inputs": {
			"mass_field": BASE_MASS.duplicate(true),
			"pressure_field": BASE_PRESSURE.duplicate(true),
			"temperature_field": BASE_TEMPERATURE.duplicate(true),
			"velocity_field": BASE_VELOCITY.duplicate(true),
			"density_field": BASE_DENSITY.duplicate(true),
			"neighbor_topology": BASE_TOPOLOGY.duplicate(true),
		}
	}

func _build_override_payload() -> Dictionary:
	return {
		"delta": 1.0,
		"inputs": {
			"field_buffers": {
				"mass": [1000.0, 1000.0],
				"pressure": [150.0, 150.0],
				"temperature": [310.0, 310.0],
				"velocity": [0.25, 0.25],
				"density": [1.1, 1.2],
				"neighbor_topology": BASE_TOPOLOGY.duplicate(true),
			},
		}
	}

func _extract_updated_mass(step_result: Dictionary) -> Array:
	var pipeline: Dictionary = step_result.get("pipeline", {})
	if typeof(pipeline) != TYPE_DICTIONARY:
		push_error("Wave-A continuity step result missing pipeline payload.")
		return []
	var field_evolution: Dictionary = pipeline.get("field_evolution", {})
	if typeof(field_evolution) != TYPE_DICTIONARY:
		push_error("Wave-A continuity step result missing field_evolution payload.")
		return []
	var updated_fields: Dictionary = field_evolution.get("updated_fields", {})
	if typeof(updated_fields) != TYPE_DICTIONARY:
		push_error("Wave-A continuity step result missing updated_fields payload.")
		return []
	var mass_variant = updated_fields.get("mass", [])
	if typeof(mass_variant) != TYPE_ARRAY:
		push_error("Wave-A continuity step result missing updated mass field array.")
		return []
	return mass_variant

func _arrays_equal(lhs: Array, rhs: Array, tolerance: float = 1.0e-12) -> bool:
	if lhs.size() != rhs.size():
		return false
	for i in range(lhs.size()):
		if abs(float(lhs[i]) - float(rhs[i])) > tolerance:
			return false
	return true

func _assert(condition: bool, message: String) -> bool:
	if not condition:
		push_error(message)
	return condition
