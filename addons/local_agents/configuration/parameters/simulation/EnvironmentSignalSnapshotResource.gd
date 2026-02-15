extends Resource
class_name LocalAgentsEnvironmentSignalSnapshotResource

@export var schema_version: int = 1
@export var tick: int = 0
@export var environment_snapshot: Dictionary = {}
@export var network_state_snapshot: Dictionary = {}
@export var transform_state: Dictionary = {}
@export var transform_diagnostics: Dictionary = {}
@export var pass_descriptor: Dictionary = {}
@export var material_model: Dictionary = {}
@export var emitter_model: Dictionary = {}
@export var dispatch_contract_status: Dictionary = {}
@export var transform_changed: bool = false
@export var transform_changed_tiles: Array = []
@export var transform_changed_chunks: Array = []

func to_dict() -> Dictionary:
	var normalized_state = _normalize_transform_state(transform_state)
	var normalized_diagnostics = _normalize_transform_diagnostics(transform_diagnostics)
	return {
		"schema_version": schema_version,
		"tick": tick,
		"environment_snapshot": environment_snapshot.duplicate(true),
		"network_state_snapshot": network_state_snapshot.duplicate(true),
		"transform_state": normalized_state,
		"transform_diagnostics": normalized_diagnostics,
		"pass_descriptor": _dictionary_or_empty(normalized_diagnostics.get("pass_descriptor", {})),
		"material_model": _dictionary_or_empty(normalized_diagnostics.get("material_model", {})),
		"emitter_model": _dictionary_or_empty(normalized_diagnostics.get("emitter_model", {})),
		"dispatch_contract_status": _dictionary_or_empty(normalized_diagnostics.get("dispatch_contract_status", {})),
		"transform_changed": bool(transform_changed),
		"transform_changed_tiles": transform_changed_tiles.duplicate(true),
		"transform_changed_chunks": transform_changed_chunks.duplicate(true),
	}

func from_dict(values: Dictionary) -> void:
	schema_version = int(values.get("schema_version", schema_version))
	tick = int(values.get("tick", tick))
	var env_variant = values.get("environment_snapshot", {})
	environment_snapshot = env_variant.duplicate(true) if env_variant is Dictionary else {}
	var water_variant = values.get("network_state_snapshot", {})
	network_state_snapshot = water_variant.duplicate(true) if water_variant is Dictionary else {}

	var transform_state_variant = values.get("transform_state", {})
	if not (transform_state_variant is Dictionary):
		transform_state_variant = {}
	transform_state = _normalize_transform_state(transform_state_variant as Dictionary)
	network_state_snapshot = _dictionary_or_empty(transform_state.get("network_state", {}))

	var transform_diagnostics_variant = values.get("transform_diagnostics", {})
	if not (transform_diagnostics_variant is Dictionary):
		transform_diagnostics_variant = {}
	transform_diagnostics = _normalize_transform_diagnostics(transform_diagnostics_variant as Dictionary)
	pass_descriptor = _dictionary_or_empty(transform_diagnostics.get("pass_descriptor", values.get("pass_descriptor", {})))
	material_model = _dictionary_or_empty(transform_diagnostics.get("material_model", values.get("material_model", {})))
	emitter_model = _dictionary_or_empty(transform_diagnostics.get("emitter_model", values.get("emitter_model", {})))
	dispatch_contract_status = _dictionary_or_empty(transform_diagnostics.get("dispatch_contract_status", values.get("dispatch_contract_status", {})))

	transform_changed = bool(values.get("transform_changed", transform_changed))
	var changed_variant = values.get("transform_changed_tiles", [])
	transform_changed_tiles = changed_variant.duplicate(true) if changed_variant is Array else []
	var changed_chunks_variant = values.get("transform_changed_chunks", [])
	transform_changed_chunks = changed_chunks_variant.duplicate(true) if changed_chunks_variant is Array else []

func _normalize_transform_state(values: Dictionary) -> Dictionary:
	if values == null:
		return {}
	return {
		"network_state": _dictionary_or_empty(values.get("network_state", {})),
		"atmosphere_state": _dictionary_or_empty(values.get("atmosphere_state", {})),
		"deformation_state": _dictionary_or_empty(values.get("deformation_state", {})),
		"exposure_state": _dictionary_or_empty(values.get("exposure_state", {})),
	}

func _normalize_transform_diagnostics(values: Dictionary) -> Dictionary:
	if values == null:
		return {}
	var normalized_pass = _dictionary_or_empty(values.get("pass_descriptor", pass_descriptor))
	var normalized_material = _dictionary_or_empty(values.get("material_model", normalized_pass.get("material_model", material_model)))
	var normalized_emitter = _dictionary_or_empty(values.get("emitter_model", normalized_pass.get("emitter_model", emitter_model)))
	var normalized_dispatch = _dictionary_or_empty(values.get("dispatch_contract_status", dispatch_contract_status))
	normalized_pass["material_model"] = normalized_material.duplicate(true)
	normalized_pass["emitter_model"] = normalized_emitter.duplicate(true)
	return {
		"pass_descriptor": normalized_pass,
		"material_model": normalized_material,
		"emitter_model": normalized_emitter,
		"dispatch_contract_status": normalized_dispatch,
	}

func _dictionary_or_empty(value) -> Dictionary:
	if value is Dictionary:
		return (value as Dictionary).duplicate(true)
	return {}
