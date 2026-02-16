extends RefCounted

const FieldRegistryConfigResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/FieldRegistryConfigResource.gd")
const EmitterProfileTableResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/EmitterProfileTableResource.gd")
const MaterialProfileTableResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/MaterialProfileTableResource.gd")
const NativeComputeBridgeScript = preload("res://addons/local_agents/simulation/controller/NativeComputeBridge.gd")
const SimulationVoxelTerrainMutatorScript = preload("res://addons/local_agents/simulation/controller/SimulationVoxelTerrainMutator.gd")
const _ENVIRONMENT_STAGE_NAME_VOXEL_TRANSFORM := "voxel_transform_step"
const _UNKNOWN_MATERIAL_ID := "material:unknown"
const _UNKNOWN_MATERIAL_PROFILE_ID := "profile:unknown"
const _UNKNOWN_MATERIAL_PHASE_ID := "phase:unknown"
const _UNKNOWN_ELEMENT_ID := "element:unknown"
const _MATERIAL_PROFILE_REQUIRED_FIELDS: Array[String] = [
	"density",
	"heat_capacity",
	"thermal_conductivity",
	"cohesion",
	"hardness",
	"porosity",
	"freeze_temp_k",
	"melt_temp_k",
	"thermal_expansion",
	"brittle_threshold",
	"fracture_toughness",
	"moisture_capacity",
]
static var _native_field_registry_session_configured: bool = false

static func ensure_native_sim_core_initialized(controller, tick: int = -1) -> bool:
	if not NativeComputeBridgeScript.is_native_sim_core_enabled():
		return true
	if _native_field_registry_session_configured:
		return true
	if not apply_native_field_registry_config(controller, null, tick):
		return false
	_native_field_registry_session_configured = true
	return true

static func generation_cap(controller, task: String, fallback: int) -> int:
	var key = "max_generations_per_tick_%s" % task
	return maxi(1, int(controller._llama_server_options.get(key, fallback)))

static func apply_native_field_registry_config(controller, config_resource, tick: int = -1) -> bool:
	if not NativeComputeBridgeScript.is_native_sim_core_enabled():
		return true
	var effective_tick = tick
	if effective_tick < 0:
		effective_tick = int(controller._last_tick_processed)
	var normalized = config_resource
	if normalized == null:
		normalized = FieldRegistryConfigResourceScript.new()
	if normalized.has_method("ensure_defaults"):
		normalized.call("ensure_defaults")
	if not normalized.has_method("to_dict"):
		return controller._emit_dependency_error(effective_tick, "native_field_registry", "invalid_config_resource")
	var payload: Dictionary = normalized.call("to_dict")
	var dispatch = NativeComputeBridgeScript.dispatch_stage_call(
		controller,
		effective_tick,
		"native_field_registry",
		"configure_field_registry",
		[payload],
		true
	)
	return bool(dispatch.get("ok", false))

static func enqueue_native_voxel_edit_ops(controller, tick: int, voxel_ops: Array, strict: bool = false) -> Dictionary:
	if not NativeComputeBridgeScript.is_native_sim_core_enabled():
		if strict:
			controller._emit_dependency_error(tick, "voxel_edit_enqueue", "native_sim_core_disabled")
		return {
			"ok": false,
			"executed": false,
			"dispatched": false,
			"error": "native_sim_core_disabled",
			"queued_count": 0,
		}
	if not ensure_native_sim_core_initialized(controller, tick):
		return {
			"ok": false,
			"executed": false,
			"dispatched": false,
			"error": "native_field_registry_unavailable",
		}
	var dispatch = NativeComputeBridgeScript.dispatch_voxel_edit_enqueue_call(
		controller,
		tick,
		"voxel_edit_enqueue",
		voxel_ops,
		strict
	)
	var native_payload = NativeComputeBridgeScript.voxel_stage_result(dispatch)
	return {
		"ok": bool(dispatch.get("ok", false)),
		"executed": bool(dispatch.get("executed", false)),
		"dispatched": NativeComputeBridgeScript.is_voxel_stage_dispatched(dispatch),
		"kernel_pass": String(dispatch.get("kernel_pass", "")),
		"backend_used": String(dispatch.get("backend_used", "")),
		"dispatch_reason": String(dispatch.get("dispatch_reason", "")),
		"result": dispatch.get("result", {}),
		"voxel_result": native_payload,
		"error": String(dispatch.get("error", "")),
		"queued_count": int(native_payload.get("queued_count", 0)),
	}

static func execute_native_voxel_stage(controller, tick: int, stage_name: StringName, payload: Dictionary = {}, strict: bool = false) -> Dictionary:
	var normalized_stage_name = String(stage_name).strip_edges().to_lower()
	var normalized_payload = _with_required_material_identity(payload)
	if normalized_stage_name == _ENVIRONMENT_STAGE_NAME_VOXEL_TRANSFORM:
		var material_contract = _inject_voxel_transform_material_contract(normalized_payload)
		if not bool(material_contract.get("ok", false)):
			var contract_error := String(material_contract.get("error", "invalid_voxel_transform_material_contract"))
			if strict:
				controller._emit_dependency_error(tick, "voxel_stage", contract_error)
			return {
				"ok": false,
				"executed": false,
				"dispatched": false,
				"kernel_pass": "",
				"backend_used": "",
				"dispatch_reason": "",
				"error": contract_error,
			}
		normalized_payload = (material_contract.get("payload", {}) as Dictionary).duplicate(true)
	if normalized_stage_name == _ENVIRONMENT_STAGE_NAME_VOXEL_TRANSFORM:
		var environment_dispatch = NativeComputeBridgeScript.dispatch_environment_stage_call(
			controller,
			tick,
			"voxel_stage",
			normalized_stage_name,
			normalized_payload,
			strict
		)
		var environment_result_variant = environment_dispatch.get("result", {})
		var environment_result: Dictionary = {}
		if environment_result_variant is Dictionary:
			environment_result = (environment_result_variant as Dictionary).duplicate(true)
		var execution_variant = environment_result.get("execution", {})
		if not (execution_variant is Dictionary):
			var nested_result_variant = environment_result.get("result", {})
			if nested_result_variant is Dictionary:
				execution_variant = (nested_result_variant as Dictionary).get("execution", {})
		var execution: Dictionary = execution_variant if execution_variant is Dictionary else {}
		var dispatched := NativeComputeBridgeScript.is_environment_stage_dispatched(environment_dispatch)
		var backend_used := _canonical_environment_backend(environment_dispatch, execution)
		var kernel_pass := String(execution.get("kernel_pass", "")).strip_edges()
		var dispatch_reason := _canonical_environment_dispatch_reason(environment_dispatch, execution, environment_result)
		var native_mutation_authority := _extract_native_mutation_authority(environment_dispatch, environment_result, execution)
		return {
			"ok": bool(environment_dispatch.get("ok", false)),
			"executed": bool(environment_dispatch.get("executed", false)),
			"dispatched": dispatched,
			"kernel_pass": kernel_pass,
			"backend_used": backend_used,
			"dispatch_reason": dispatch_reason,
			"result": environment_dispatch.get("result", {}),
			"voxel_result": NativeComputeBridgeScript.environment_stage_result(environment_dispatch),
			"native_mutation_authority": native_mutation_authority,
			"error": String(environment_dispatch.get("error", "")),
		}
	if not NativeComputeBridgeScript.is_native_sim_core_enabled():
		if strict:
			controller._emit_dependency_error(tick, "voxel_stage", "native_sim_core_disabled")
		return {
			"ok": false,
			"executed": false,
			"dispatched": false,
			"kernel_pass": "",
			"backend_used": "",
			"dispatch_reason": "",
			"error": "native_sim_core_disabled",
		}
	if not ensure_native_sim_core_initialized(controller, tick):
		return {
			"ok": false,
			"executed": false,
			"dispatched": false,
			"kernel_pass": "",
			"backend_used": "",
			"dispatch_reason": "",
			"error": "native_field_registry_unavailable",
		}
	var dispatch = NativeComputeBridgeScript.dispatch_voxel_stage(stage_name, normalized_payload)
	if strict and not bool(dispatch.get("ok", false)) and controller != null and controller.has_method("_emit_dependency_error"):
		controller._emit_dependency_error(tick, "voxel_stage", String(dispatch.get("error", "core_call_failed_execute_voxel_stage")))
	return {
		"ok": bool(dispatch.get("ok", false)),
		"executed": bool(dispatch.get("executed", false)),
		"dispatched": NativeComputeBridgeScript.is_voxel_stage_dispatched(dispatch),
		"kernel_pass": String(dispatch.get("kernel_pass", "")),
		"backend_used": String(dispatch.get("backend_used", "")),
		"dispatch_reason": String(dispatch.get("dispatch_reason", "")),
		"result": dispatch.get("result", {}),
		"voxel_result": NativeComputeBridgeScript.voxel_stage_result(dispatch),
		"native_mutation_authority": _extract_native_mutation_authority(dispatch, NativeComputeBridgeScript.voxel_stage_result(dispatch), {}),
		"error": String(dispatch.get("error", "")),
	}

static func _canonical_environment_backend(environment_dispatch: Dictionary, execution: Dictionary) -> String:
	var backend_used := String(execution.get("backend_used", "")).strip_edges().to_lower()
	if backend_used != "":
		return backend_used
	var backend_requested := String(execution.get("backend_requested", "")).strip_edges().to_lower()
	if backend_requested != "":
		return backend_requested
	var native_result_variant = environment_dispatch.get("result", {})
	if not (native_result_variant is Dictionary):
		return ""
	var native_result = native_result_variant as Dictionary
	var dispatch_execution_variant = native_result.get("execution", {})
	if dispatch_execution_variant is Dictionary:
		var dispatch_execution = dispatch_execution_variant as Dictionary
		backend_used = String(dispatch_execution.get("backend_used", "")).strip_edges().to_lower()
		if backend_used != "":
			return backend_used
		backend_requested = String(dispatch_execution.get("backend_requested", "")).strip_edges().to_lower()
		if backend_requested != "":
			return backend_requested
	return ""

static func _canonical_environment_dispatch_reason(environment_dispatch: Dictionary, execution: Dictionary, environment_result: Dictionary) -> String:
	var dispatch_reason := String(execution.get("dispatch_reason", "")).strip_edges()
	if dispatch_reason != "":
		return dispatch_reason
	var native_result_variant = environment_dispatch.get("result", {})
	if native_result_variant is Dictionary:
		var native_result = native_result_variant as Dictionary
		var dispatch_execution_variant = native_result.get("execution", {})
		if dispatch_execution_variant is Dictionary:
			dispatch_reason = String((dispatch_execution_variant as Dictionary).get("dispatch_reason", "")).strip_edges()
			if dispatch_reason != "":
				return dispatch_reason
	return String(environment_result.get("status", "")).strip_edges()

static func _extract_native_mutation_authority(dispatch: Dictionary, payload: Dictionary, execution: Dictionary) -> Dictionary:
	var authority: Dictionary = {}
	if not execution.is_empty():
		authority = _merge_native_authority_fields(authority, execution)
	authority = _merge_native_authority_fields(authority, payload)
	authority = _merge_native_authority_fields(authority, dispatch)
	return authority

static func _merge_native_authority_fields(current: Dictionary, source: Dictionary) -> Dictionary:
	var merged := current.duplicate(true)
	if source.has("ops_changed"):
		merged["ops_changed"] = maxi(0, int(source.get("ops_changed", 0)))
	if source.has("changed"):
		merged["changed"] = bool(source.get("changed", false))
	elif source.has("voxel_changed") and not merged.has("changed"):
		merged["changed"] = bool(source.get("voxel_changed", false))
	if source.has("changed_chunks"):
		var changed_chunks_variant = source.get("changed_chunks", [])
		if changed_chunks_variant is Array:
			merged["changed_chunks"] = (changed_chunks_variant as Array).duplicate(true)
	if source.has("changed_region"):
		var changed_region_variant = source.get("changed_region", {})
		if changed_region_variant is Dictionary:
			merged["changed_region"] = (changed_region_variant as Dictionary).duplicate(true)
	return merged

static func _with_required_material_identity(payload: Dictionary) -> Dictionary:
	var normalized: Dictionary = payload.duplicate(true)
	var input_variant = normalized.get("inputs", {})
	var inputs: Dictionary = {}
	if input_variant is Dictionary:
		inputs = (input_variant as Dictionary).duplicate(true)
	var material_identity_variant = normalized.get("material_identity", {})
	var material_identity: Dictionary = {}
	if material_identity_variant is Dictionary:
		material_identity = (material_identity_variant as Dictionary).duplicate(true)
	var material_id := String(material_identity.get("material_id", normalized.get("material_id", inputs.get("material_id", _UNKNOWN_MATERIAL_ID)))).strip_edges()
	if material_id == "":
		material_id = _UNKNOWN_MATERIAL_ID
	var material_profile_id := String(
		material_identity.get("material_profile_id", normalized.get("material_profile_id", inputs.get("material_profile_id", _UNKNOWN_MATERIAL_PROFILE_ID)))
	).strip_edges()
	if material_profile_id == "":
		material_profile_id = _UNKNOWN_MATERIAL_PROFILE_ID
	var phase_source = material_identity.get(
		"material_phase_id",
		normalized.get("material_phase_id", inputs.get("material_phase_id", normalized.get("phase", inputs.get("phase", _UNKNOWN_MATERIAL_PHASE_ID))))
	)
	var material_phase_id := _canonical_phase_id_from_value(phase_source)
	if material_phase_id == "":
		material_phase_id = _UNKNOWN_MATERIAL_PHASE_ID
	var element_id := String(material_identity.get("element_id", normalized.get("element_id", inputs.get("element_id", _UNKNOWN_ELEMENT_ID)))).strip_edges()
	if element_id == "":
		element_id = _UNKNOWN_ELEMENT_ID
	material_identity["material_id"] = material_id
	material_identity["material_profile_id"] = material_profile_id
	material_identity["material_phase_id"] = material_phase_id
	material_identity["element_id"] = element_id
	inputs["material_id"] = material_id
	inputs["material_profile_id"] = material_profile_id
	inputs["material_phase_id"] = material_phase_id
	inputs["element_id"] = element_id
	normalized["inputs"] = inputs
	normalized["material_identity"] = material_identity
	return normalized

static func _inject_voxel_transform_material_contract(payload: Dictionary) -> Dictionary:
	var normalized := _with_required_material_identity(payload)
	var identity_variant = normalized.get("material_identity", {})
	var material_identity: Dictionary = {}
	if identity_variant is Dictionary:
		material_identity = (identity_variant as Dictionary).duplicate(true)
	var material_id := String(material_identity.get("material_id", _UNKNOWN_MATERIAL_ID)).strip_edges()
	if material_id == "":
		material_id = _UNKNOWN_MATERIAL_ID
	var element_id := String(material_identity.get("element_id", _UNKNOWN_ELEMENT_ID)).strip_edges()
	if element_id == "":
		element_id = _UNKNOWN_ELEMENT_ID

	var table := MaterialProfileTableResourceScript.new()
	table.ensure_defaults()
	var resolved_profile = table.resolve_profile(material_id)
	var profile_validation = table.validate_profile(resolved_profile)
	if not bool(profile_validation.get("ok", false)):
		return {
			"ok": false,
			"error": "invalid_material_profile_required_fields",
			"missing_fields": profile_validation.get("missing_fields", []),
		}
	for key in _MATERIAL_PROFILE_REQUIRED_FIELDS:
		if not resolved_profile.has(key):
			return {
				"ok": false,
				"error": "invalid_material_profile_required_fields",
				"missing_fields": [key],
			}
		resolved_profile[key] = float(resolved_profile.get(key, 0.0))

	var profile_key := String(resolved_profile.get("profile_key", "unknown")).strip_edges()
	if profile_key == "":
		profile_key = "unknown"
	var material_profile_id := String(material_identity.get("material_profile_id", normalized.get("material_profile_id", "profile:%s" % profile_key))).strip_edges()
	if material_profile_id == "":
		material_profile_id = "profile:%s" % profile_key
	var phase_source = material_identity.get(
		"material_phase_id",
		normalized.get("material_phase_id", normalized.get("phase", (normalized.get("inputs", {}) as Dictionary).get("phase", _UNKNOWN_MATERIAL_PHASE_ID)))
	)
	var material_phase_id := _canonical_phase_id_from_value(phase_source)
	if material_phase_id == "":
		material_phase_id = _UNKNOWN_MATERIAL_PHASE_ID
	material_identity["material_id"] = material_id
	material_identity["material_profile_id"] = material_profile_id
	material_identity["material_phase_id"] = material_phase_id
	material_identity["element_id"] = element_id
	normalized["material_identity"] = material_identity
	normalized["material_profile"] = resolved_profile

	var pass_descriptor_variant = normalized.get("pass_descriptor", {})
	var pass_descriptor: Dictionary = {}
	if pass_descriptor_variant is Dictionary:
		pass_descriptor = (pass_descriptor_variant as Dictionary).duplicate(true)
	pass_descriptor["material_model"] = {
		"material_id": material_id,
		"material_profile_id": material_profile_id,
		"material_phase_id": material_phase_id,
		"element_id": element_id,
		"profile_version": int(table.schema_version),
		"profile_key": profile_key,
	}
	var emitter_contract_result = _inject_voxel_transform_emitter_contract(normalized)
	if not bool(emitter_contract_result.get("ok", false)):
		return emitter_contract_result
	var normalized_from_emitter_variant = emitter_contract_result.get("payload", normalized)
	if normalized_from_emitter_variant is Dictionary:
		normalized = (normalized_from_emitter_variant as Dictionary).duplicate(true)
	var emitters_variant = normalized.get("emitters", {})
	var emitters: Dictionary = {}
	if emitters_variant is Dictionary:
		emitters = (emitters_variant as Dictionary).duplicate(true)
	pass_descriptor["emitter_model"] = {
		"profile_version": int(emitters.get("schema_version", 1)),
		"preset_table_key": String(emitters.get("preset_table_key", "generic_emitters_v2")).strip_edges(),
		"profile_key": String(emitters.get("preset_table_key", "generic_emitters_v2")).strip_edges(),
		"enabled": bool(emitters.get("enabled", true)),
		"radiant_heat_enabled": bool(emitters.get("radiant_heat_enabled", true)),
	}
	normalized["pass_descriptor"] = pass_descriptor
	return {"ok": true, "payload": normalized}

static func _canonical_phase_id_from_value(raw_value) -> String:
	if raw_value is String:
		var raw_string := String(raw_value).strip_edges().to_lower()
		if raw_string == "":
			return _UNKNOWN_MATERIAL_PHASE_ID
		if raw_string.begins_with("phase:"):
			return raw_string
		if raw_string in ["solid", "liquid", "gas", "plasma"]:
			return "phase:%s" % raw_string
		return "phase:%s" % raw_string
	var phase_index := int(raw_value)
	match phase_index:
		0:
			return "phase:solid"
		1:
			return "phase:liquid"
		2:
			return "phase:gas"
		3:
			return "phase:plasma"
		_:
			return _UNKNOWN_MATERIAL_PHASE_ID

static func _inject_voxel_transform_emitter_contract(payload: Dictionary) -> Dictionary:
	var normalized: Dictionary = payload.duplicate(true)
	var emitter_table := EmitterProfileTableResourceScript.new()
	emitter_table.ensure_defaults()
	var default_emitters = emitter_table.default_contract_dict()
	var emitters_variant = normalized.get("emitters", null)
	if emitters_variant == null:
		normalized["emitters"] = default_emitters
		return {"ok": true, "payload": normalized}
	if not (emitters_variant is Dictionary):
		return {
			"ok": false,
			"error": "invalid_emitters_schema_type",
			"details": {"expected": "Dictionary", "observed": typeof(emitters_variant)},
		}
	var provided = (emitters_variant as Dictionary).duplicate(true)
	var merged: Dictionary = default_emitters.duplicate(true)
	if provided.has("schema_version"):
		merged["schema_version"] = int(provided.get("schema_version", merged.get("schema_version", 1)))
	if provided.has("preset_table_key"):
		var key = String(provided.get("preset_table_key", merged.get("preset_table_key", "generic_emitters_v2"))).strip_edges()
		var normalized_key = "generic_emitters_v2" if key == "" else key
		merged["preset_table_key"] = normalized_key
	if provided.has("enabled"):
		merged["enabled"] = bool(provided.get("enabled", true))
	if provided.has("radiant_heat_enabled"):
		merged["radiant_heat_enabled"] = bool(provided.get("radiant_heat_enabled", true))
	if provided.has("presets"):
		var presets_variant = provided.get("presets", [])
		if not (presets_variant is Array):
			return {
				"ok": false,
				"error": "invalid_emitters_presets_type",
				"details": {"expected": "Array", "observed": typeof(presets_variant)},
			}
		var provided_presets = presets_variant as Array
		var preset_index: Dictionary = {}
		for preset_variant in merged.get("presets", []):
			if preset_variant is Dictionary:
				var preset_row = preset_variant as Dictionary
				var preset_id = String(preset_row.get("preset_id", "")).strip_edges().to_lower()
				if preset_id != "":
					preset_index[preset_id] = preset_row.duplicate(true)
		for provided_preset_variant in provided_presets:
			if not (provided_preset_variant is Dictionary):
				return {
					"ok": false,
					"error": "invalid_emitters_preset_row_type",
				}
			var provided_preset = provided_preset_variant as Dictionary
			var preset_id = String(provided_preset.get("preset_id", "")).strip_edges().to_lower()
			if preset_id == "":
				return {
					"ok": false,
					"error": "invalid_emitters_preset_id",
				}
			var base_preset_variant = preset_index.get(preset_id, {
				"preset_id": preset_id,
				"enabled": true,
				"radiant_heat": 0.0,
				"temperature_k": 0.0,
			})
			var base_preset: Dictionary = {}
			if base_preset_variant is Dictionary:
				base_preset = (base_preset_variant as Dictionary).duplicate(true)
			base_preset["preset_id"] = preset_id
			if provided_preset.has("enabled"):
				base_preset["enabled"] = bool(provided_preset.get("enabled", base_preset.get("enabled", true)))
			if provided_preset.has("radiant_heat"):
				base_preset["radiant_heat"] = float(provided_preset.get("radiant_heat", base_preset.get("radiant_heat", 0.0)))
			if provided_preset.has("temperature_k"):
				base_preset["temperature_k"] = float(provided_preset.get("temperature_k", base_preset.get("temperature_k", 0.0)))
			preset_index[preset_id] = base_preset
		var merged_presets: Array[Dictionary] = []
		for preset_key in preset_index.keys():
			var preset_row_variant = preset_index.get(preset_key, {})
			if preset_row_variant is Dictionary:
				merged_presets.append((preset_row_variant as Dictionary).duplicate(true))
		merged["presets"] = merged_presets
	var validation = emitter_table.validate_emitters_contract(merged)
	if not bool(validation.get("ok", false)):
		return {
			"ok": false,
			"error": "invalid_emitters_schema_fields",
			"errors": validation.get("errors", []),
		}
	normalized["emitters"] = merged
	return {"ok": true, "payload": normalized}

static func stamp_default_voxel_target_wall(controller, tick: int, camera_transform: Transform3D, target_wall_profile = null, strict: bool = false) -> Dictionary:
	if controller == null:
		return {"ok": false, "changed": false, "error": "invalid_controller", "tick": tick}
	var mutation = SimulationVoxelTerrainMutatorScript.stamp_default_target_wall(controller, tick, camera_transform, target_wall_profile)
	if not bool(mutation.get("ok", false)) and strict:
		controller._emit_dependency_error(tick, "voxel_target_wall", String(mutation.get("error", "wall_stamp_failed")))
	return mutation

static func enqueue_thought_npcs(controller, npc_ids: Array) -> void:
	for npc_id_variant in npc_ids:
		var npc_id = String(npc_id_variant).strip_edges()
		if npc_id == "" or controller._pending_thought_npc_ids.has(npc_id):
			continue
		controller._pending_thought_npc_ids.append(npc_id)

static func enqueue_dream_npcs(controller, npc_ids: Array) -> void:
	for npc_id_variant in npc_ids:
		var npc_id = String(npc_id_variant).strip_edges()
		if npc_id == "" or controller._pending_dream_npc_ids.has(npc_id):
			continue
		controller._pending_dream_npc_ids.append(npc_id)

static func enqueue_dialogue_pairs(controller, npc_ids: Array) -> void:
	if npc_ids.size() < 2:
		return
	for index in range(0, npc_ids.size() - 1, 2):
		var source_id = String(npc_ids[index]).strip_edges()
		var target_id = String(npc_ids[index + 1]).strip_edges()
		if source_id == "" or target_id == "":
			continue
		var pair_key = "%s|%s" % [source_id, target_id]
		var already_queued = false
		for pair_variant in controller._pending_dialogue_pairs:
			if not (pair_variant is Dictionary):
				continue
			var pair = pair_variant as Dictionary
			if "%s|%s" % [String(pair.get("source_id", "")), String(pair.get("target_id", ""))] == pair_key:
				already_queued = true
				break
		if not already_queued:
			controller._pending_dialogue_pairs.append({
				"source_id": source_id,
				"target_id": target_id,
			})

static func drain_thought_queue(controller, tick: int, limit: int) -> bool:
	var consumed = 0
	while consumed < limit and not controller._pending_thought_npc_ids.is_empty():
		var npc_id = String(controller._pending_thought_npc_ids[0]).strip_edges()
		controller._pending_thought_npc_ids.remove_at(0)
		if npc_id == "":
			continue
		if not controller._run_thought_cycle(npc_id, tick):
			return false
		consumed += 1
	return true

static func drain_dream_queue(controller, tick: int, limit: int) -> bool:
	var consumed = 0
	while consumed < limit and not controller._pending_dream_npc_ids.is_empty():
		var npc_id = String(controller._pending_dream_npc_ids[0]).strip_edges()
		controller._pending_dream_npc_ids.remove_at(0)
		if npc_id == "":
			continue
		if not controller._run_dream_cycle(npc_id, tick):
			return false
		consumed += 1
	return true

static func drain_dialogue_queue(controller, tick: int, limit: int) -> bool:
	var consumed = 0
	while consumed < limit and not controller._pending_dialogue_pairs.is_empty():
		var pair_variant = controller._pending_dialogue_pairs[0]
		controller._pending_dialogue_pairs.remove_at(0)
		if not (pair_variant is Dictionary):
			continue
		var pair = pair_variant as Dictionary
		var source_id = String(pair.get("source_id", "")).strip_edges()
		var target_id = String(pair.get("target_id", "")).strip_edges()
		if source_id == "" or target_id == "":
			continue
		if not controller._run_dialogue_pair(source_id, target_id, tick):
			return false
		consumed += 1
	return true

static func apply_need_decay(controller, npc_id: String, fixed_delta: float) -> void:
	var state = controller._villagers.get(npc_id, null)
	if state == null:
		return
	state.energy = clampf(float(state.energy) - (0.004 * fixed_delta), 0.0, 1.0)
	state.hunger = clampf(float(state.hunger) + (0.006 * fixed_delta), 0.0, 1.0)

	var econ_state = controller._individual_ledgers.get(npc_id, null)
	if econ_state != null:
		econ_state.energy = clampf(float(state.energy), 0.0, 1.0)
		controller._individual_ledgers[npc_id] = controller._individual_ledger_system.ensure_bounds(econ_state)

static func generate_narrator_direction(controller, tick: int) -> bool:
	var seed = controller._rng.derive_seed("narrator", controller.world_id, controller.active_branch_id, tick)
	var result = controller._narrator.generate_direction(controller.current_snapshot(tick), seed, controller._directive_text())
	if not bool(result.get("ok", false)):
		return controller._emit_dependency_error(tick, "narrator", String(result.get("error", "narrator_failed")))
	controller._persist_llm_trace_event(tick, "narrator_direction", [], result.get("trace", {}))
	controller.emit_signal("narrator_direction_generated", tick, result.get("text", ""))
	return true

static func run_dialogue_cycle(controller, npc_ids: Array, tick: int) -> bool:
	if npc_ids.size() < 2:
		return true
	for index in range(0, npc_ids.size() - 1, 2):
		var source_id = String(npc_ids[index]).strip_edges()
		var target_id = String(npc_ids[index + 1]).strip_edges()
		if source_id == "" or target_id == "":
			continue
		if not controller._run_dialogue_pair(source_id, target_id, tick):
			return false
	return true

static func run_structure_lifecycle(controller, tick: int) -> void:
	controller._structure_lifecycle_events = _empty_structure_lifecycle_events()
	if not NativeComputeBridgeScript.is_native_sim_core_enabled():
		controller._emit_dependency_error(tick, "structure_lifecycle", "gpu_required")
		return
	if not Engine.has_singleton(NativeComputeBridgeScript.NATIVE_SIM_CORE_SINGLETON_NAME):
		controller._emit_dependency_error(tick, "structure_lifecycle", "native_required")
		return
	var native_core = Engine.get_singleton(NativeComputeBridgeScript.NATIVE_SIM_CORE_SINGLETON_NAME)
	if native_core == null or not native_core.has_method("step_structure_lifecycle"):
		controller._emit_dependency_error(tick, "structure_lifecycle", "native_required")
		return
	if not ensure_native_sim_core_initialized(controller, tick):
		controller._emit_dependency_error(tick, "structure_lifecycle", "native_required")
		return
	var lifecycle_payload: Dictionary = {
		"config": controller._structure_lifecycle_config.to_dict() if controller._structure_lifecycle_config != null and controller._structure_lifecycle_config.has_method("to_dict") else {},
		"structures": controller._structure_lifecycle_system.export_structures() if controller._structure_lifecycle_system != null else {},
		"anchors": controller._structure_lifecycle_system.export_anchors() if controller._structure_lifecycle_system != null else [],
		"runtime_state": controller._structure_lifecycle_system.export_runtime_state() if controller._structure_lifecycle_system != null else {},
		"household_members": controller._household_member_counts(),
		"household_metrics": controller._household_growth_metrics.duplicate(true),
		"household_positions": controller._household_positions.duplicate(true),
		"water_snapshot": controller._network_state_snapshot.duplicate(true),
	}
	var dispatch = NativeComputeBridgeScript.dispatch_stage_call(
		controller,
		tick,
		"structure_lifecycle",
		"step_structure_lifecycle",
		[tick, lifecycle_payload],
		false
	)
	if not bool(dispatch.get("ok", false)):
		controller._emit_dependency_error(
			tick,
			"structure_lifecycle",
			_structure_lifecycle_native_requirement_error(String(dispatch.get("error", "native_required")))
		)
		return
	var native_result = dispatch.get("result", {})
	var native_payload: Dictionary = native_result if native_result is Dictionary else {}
	var native_structures: Dictionary = native_payload.get("structures", {}) if native_payload.get("structures", {}) is Dictionary else {}
	var native_anchors: Array = native_payload.get("anchors", []) if native_payload.get("anchors", []) is Array else []
	var native_runtime_state: Dictionary = native_payload.get("runtime_state", {}) if native_payload.get("runtime_state", {}) is Dictionary else {}
	if controller._structure_lifecycle_system != null:
		controller._structure_lifecycle_system.import_lifecycle_state(
			native_structures,
			native_anchors,
			native_runtime_state
		)
	controller._structure_lifecycle_events = {
		"expanded": native_payload.get("expanded", []),
		"abandoned": native_payload.get("abandoned", []),
		"camps": native_payload.get("camps", []),
		"path_extensions": native_payload.get("path_extensions", []),
	}
	_log_structure_lifecycle_events(controller, tick, controller._structure_lifecycle_events)

static func _empty_structure_lifecycle_events() -> Dictionary:
	return {
		"expanded": [],
		"abandoned": [],
		"camps": [],
		"path_extensions": [],
	}

static func _structure_lifecycle_native_requirement_error(raw_error: String) -> String:
	var lowered := raw_error.strip_edges().to_lower()
	if lowered.find("gpu") != -1 or lowered.find("native_sim_core_disabled") != -1:
		return "gpu_required"
	if lowered.find("native") != -1 or lowered.find("core_missing_method") != -1 or lowered.find("missing_method") != -1:
		return "native_required"
	return "native_required"

static func _log_structure_lifecycle_events(controller, tick: int, events: Dictionary) -> void:
	var expanded: Array = events.get("expanded", []) if events.get("expanded", []) is Array else []
	var abandoned: Array = events.get("abandoned", []) if events.get("abandoned", []) is Array else []
	var camps: Array = events.get("camps", []) if events.get("camps", []) is Array else []
	var path_extensions: Array = events.get("path_extensions", []) if events.get("path_extensions", []) is Array else []
	if not expanded.is_empty():
		controller._log_resource_event(tick, "sim_structure_event", "settlement", "settlement_main", {
			"kind": "structure_expansion",
			"structure_ids": expanded,
		})
	if not abandoned.is_empty():
		controller._log_resource_event(tick, "sim_structure_event", "settlement", "settlement_main", {
			"kind": "structure_abandonment",
			"structure_ids": abandoned,
		})
	if not camps.is_empty():
		var camp_ids: Array = []
		for camp_variant in camps:
			if not (camp_variant is Dictionary):
				continue
			var camp_row = camp_variant as Dictionary
			var camp_id = String(camp_row.get("structure_id", "")).strip_edges()
			if camp_id != "":
				camp_ids.append(camp_id)
		if not camp_ids.is_empty():
			controller._log_resource_event(tick, "sim_structure_event", "settlement", "settlement_main", {
				"kind": "structure_camp_spawn",
				"structure_ids": camp_ids,
			})
	if not path_extensions.is_empty():
		controller._log_resource_event(tick, "sim_structure_event", "settlement", "settlement_main", {
			"kind": "structure_path_extension",
			"events": path_extensions,
		})

static func assert_resource_invariants(controller, tick: int, npc_ids: Array) -> void:
	for key in ["food", "water", "wood", "stone", "tools", "currency", "labor_pool", "waste"]:
		var value = float(controller._community_ledger.to_dict().get(key, 0.0))
		if value < -0.000001:
			controller._emit_dependency_error(tick, "resource_invariant", "community_negative_" + key)

	var household_ids = controller._household_ledgers.keys()
	household_ids.sort()
	for hid in household_ids:
		var ledger = controller._household_ledgers.get(String(hid), null)
		if ledger == null:
			continue
		var row = ledger.to_dict()
		for key in ["food", "water", "wood", "stone", "tools", "currency", "debt", "waste"]:
			if float(row.get(key, 0.0)) < -0.000001:
				controller._emit_dependency_error(tick, "resource_invariant", "household_negative_" + key)

	for npc_id in npc_ids:
		var state = controller._individual_ledgers.get(npc_id, null)
		if state == null:
			continue
		var row = state.to_dict()
		var inv: Dictionary = row.get("inventory", {})
		for key in ["food", "water", "currency", "tools", "waste"]:
			if float(inv.get(key, 0.0)) < -0.000001:
				controller._emit_dependency_error(tick, "resource_invariant", "individual_negative_" + key)
		if float(row.get("wage_due", 0.0)) < -0.000001:
			controller._emit_dependency_error(tick, "resource_invariant", "individual_negative_wage_due")

static func log_resource_event(controller, tick: int, event_type: String, scope: String, owner_id: String, payload: Dictionary) -> void:
	if not controller.resource_event_logging_enabled:
		return
	if controller._store == null:
		return
	var normalized_scope = scope.strip_edges()
	if normalized_scope == "":
		normalized_scope = "settlement"
	var normalized_owner = owner_id.strip_edges()
	if normalized_owner == "":
		normalized_owner = "settlement_main"
	var bundle = controller.BundleResourceScript.new()
	bundle.from_dict(payload)
	var normalized = payload.duplicate(true)
	if not bundle.to_dict().is_empty():
		normalized["resource_bundle"] = bundle.to_dict()
	var event_id: int = controller._store.append_resource_event(controller.world_id, controller.active_branch_id, tick, controller._resource_event_sequence, event_type, normalized_scope, normalized_owner, normalized)
	if event_id == -1:
		controller._store.open(controller._store_path_for_instance())
		event_id = controller._store.append_resource_event(controller.world_id, controller.active_branch_id, tick, controller._resource_event_sequence, event_type, normalized_scope, normalized_owner, normalized)
	if event_id == -1:
		controller._emit_dependency_error(tick, "resource_event_store", "append_failed")
	controller._resource_event_sequence += 1

static func persist_llm_trace_event(controller, tick: int, task: String, actor_ids: Array, trace_variant) -> void:
	if not controller.resource_event_logging_enabled:
		return
	if not (trace_variant is Dictionary):
		return
	var trace: Dictionary = trace_variant
	if trace.is_empty():
		return
	var query_keys: Array = trace.get("query_keys", [])
	var referenced_ids: Array = trace.get("referenced_ids", [])
	var normalized_actors: Array = controller._normalize_id_array(actor_ids)
	var normalized_referenced: Array = controller._normalize_id_array(referenced_ids)
	var profile_id = String(trace.get("profile_id", "")).strip_edges()
	var sampler_params: Dictionary = {}
	var sampler_variant = trace.get("sampler_params", {})
	if sampler_variant is Dictionary:
		sampler_params = (sampler_variant as Dictionary).duplicate(true)
	var payload := {
		"kind": "llm_trace",
		"task": task,
		"actor_ids": normalized_actors,
		"profile_id": profile_id,
		"seed": int(trace.get("seed", 0)),
		"query_keys": controller._normalize_id_array(query_keys),
		"referenced_ids": normalized_referenced,
		"sampler_params": sampler_params,
	}
	if controller._store == null:
		controller._emit_dependency_error(tick, "llm_trace_store", "store_unavailable")
		return
	var scope = "settlement"
	var owner_id = "settlement_main"
	if normalized_actors.size() == 1:
		scope = "individual"
		owner_id = String(normalized_actors[0])
	elif normalized_referenced.size() == 1:
		scope = "individual"
		owner_id = String(normalized_referenced[0])
	controller._log_resource_event(tick, "sim_llm_trace_event", scope, owner_id, payload)
