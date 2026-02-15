extends Resource
class_name LocalAgentsVoxelTimelapseSnapshotResource

@export var schema_version: int = 1
@export var tick: int = 0
@export var time_of_day: float = 0.0
@export var simulated_year: float = -8000.0
@export var simulated_seconds: float = 0.0
@export var world: Dictionary = {}
@export var transform_state: Dictionary = {}
@export var transform_diagnostics: Dictionary = {}
@export var pass_descriptor: Dictionary = {}
@export var material_model: Dictionary = {}
@export var emitter_model: Dictionary = {}
@export var dispatch_contract_status: Dictionary = {}

func to_dict() -> Dictionary:
	return {
			"schema_version": schema_version,
			"tick": tick,
			"time_of_day": time_of_day,
			"simulated_year": simulated_year,
			"simulated_seconds": simulated_seconds,
			"world": world.duplicate(true),
		"transform_state": _normalize_transform_state(transform_state),
		"transform_diagnostics": _normalize_transform_diagnostics(transform_diagnostics),
		"pass_descriptor": pass_descriptor.duplicate(true),
		"material_model": material_model.duplicate(true),
		"emitter_model": emitter_model.duplicate(true),
		"dispatch_contract_status": dispatch_contract_status.duplicate(true),
	}

func from_dict(values: Dictionary) -> void:
	schema_version = int(values.get("schema_version", schema_version))
	tick = int(values.get("tick", tick))
	time_of_day = clampf(float(values.get("time_of_day", time_of_day)), 0.0, 1.0)
	simulated_year = float(values.get("simulated_year", simulated_year))
	simulated_seconds = maxf(0.0, float(values.get("simulated_seconds", simulated_seconds)))
	var world_variant = values.get("world", {})
	world = world_variant.duplicate(true) if world_variant is Dictionary else {}
	var transform_state_variant = values.get("transform_state", {})
	if not (transform_state_variant is Dictionary):
		transform_state_variant = {}
	transform_state = _normalize_transform_state(transform_state_variant as Dictionary)

	var transform_diagnostics_variant = values.get("transform_diagnostics", {})
	if not (transform_diagnostics_variant is Dictionary):
		transform_diagnostics_variant = {}
	transform_diagnostics = _normalize_transform_diagnostics(transform_diagnostics_variant as Dictionary)
	pass_descriptor = _dictionary_or_empty(transform_diagnostics.get("pass_descriptor", values.get("pass_descriptor", {})))
	material_model = _dictionary_or_empty(transform_diagnostics.get("material_model", values.get("material_model", {})))
	emitter_model = _dictionary_or_empty(transform_diagnostics.get("emitter_model", values.get("emitter_model", {})))
	dispatch_contract_status = _dictionary_or_empty(transform_diagnostics.get("dispatch_contract_status", values.get("dispatch_contract_status", {})))

func _normalize_transform_state(values: Dictionary) -> Dictionary:
	return {
		"network_state": _dictionary_or_empty(values.get("network_state", {})),
		"atmosphere_state": _dictionary_or_empty(values.get("atmosphere_state", {})),
		"deformation_state": _dictionary_or_empty(values.get("deformation_state", {})),
		"exposure_state": _dictionary_or_empty(values.get("exposure_state", {})),
	}

func _normalize_transform_diagnostics(values: Dictionary) -> Dictionary:
	var normalized_pass = _dictionary_or_empty(values.get("pass_descriptor", pass_descriptor))
	var normalized_material = _dictionary_or_empty(values.get("material_model", normalized_pass.get("material_model", material_model)))
	var normalized_emitter = _dictionary_or_empty(values.get("emitter_model", normalized_pass.get("emitter_model", emitter_model)))
	normalized_pass["material_model"] = normalized_material.duplicate(true)
	normalized_pass["emitter_model"] = normalized_emitter.duplicate(true)
	return {
		"pass_descriptor": normalized_pass,
		"material_model": normalized_material,
		"emitter_model": normalized_emitter,
		"dispatch_contract_status": _dictionary_or_empty(values.get("dispatch_contract_status", dispatch_contract_status)),
	}

func _dictionary_or_empty(value) -> Dictionary:
	if value is Dictionary:
		return (value as Dictionary).duplicate(true)
	return {}
