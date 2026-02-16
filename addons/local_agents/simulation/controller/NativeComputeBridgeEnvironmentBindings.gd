extends RefCounted

const PhysicsServerContactBridgeScript = preload("res://addons/local_agents/simulation/controller/PhysicsServerContactBridge.gd")

static func normalize_environment_payload(payload: Dictionary, unknown_profile_id: String, unknown_phase_id: String) -> Dictionary:
	var normalized: Dictionary = payload.duplicate(true)
	var contacts := extract_contact_rows(normalized)
	if not contacts.is_empty():
		normalized["physics_server_contacts"] = contacts
		normalized["physics_contacts"] = contacts.duplicate(true)
	var inputs_variant = normalized.get("inputs", {})
	var inputs: Dictionary = {}
	if inputs_variant is Dictionary:
		inputs = (inputs_variant as Dictionary).duplicate(true)
	var material_identity := material_identity_from_payload(normalized, inputs, unknown_profile_id, unknown_phase_id)
	inputs["material_id"] = String(material_identity.get("material_id", "material:unknown")).strip_edges()
	inputs["material_profile_id"] = String(material_identity.get("material_profile_id", unknown_profile_id)).strip_edges()
	inputs["material_phase_id"] = String(material_identity.get("material_phase_id", unknown_phase_id)).strip_edges()
	inputs["element_id"] = String(material_identity.get("element_id", "element:unknown")).strip_edges()
	normalized["inputs"] = inputs
	normalized["material_identity"] = material_identity
	return normalized

static func extract_contact_rows(payload: Dictionary) -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	for key in ["physics_server_contacts", "physics_contacts", "contact_samples"]:
		var samples = payload.get(key, [])
		if not (samples is Array):
			continue
		for sample in (samples as Array):
			if sample is Dictionary:
				rows.append((sample as Dictionary).duplicate(true))
	if rows.is_empty():
		var candidates_variant = payload.get("physics_contact_candidates", payload.get("contact_candidates", []))
		if candidates_variant is Array:
			for sample in PhysicsServerContactBridgeScript.sample_contact_rows(candidates_variant as Array):
				if sample is Dictionary:
					rows.append((sample as Dictionary).duplicate(true))
	return rows

static func apply_native_contact_snapshot(payload: Dictionary, snapshot_variant) -> Dictionary:
	var normalized: Dictionary = payload.duplicate(true)
	if not (snapshot_variant is Dictionary):
		return normalized
	var snapshot := (snapshot_variant as Dictionary).duplicate(true)
	var buffered_variant = snapshot.get("buffered_rows", [])
	var buffered_rows: Array[Dictionary] = []
	if buffered_variant is Array:
		for row_variant in (buffered_variant as Array):
			if row_variant is Dictionary:
				buffered_rows.append((row_variant as Dictionary).duplicate(true))
	if not buffered_rows.is_empty():
		normalized["physics_server_contacts"] = buffered_rows
	normalized["physics_contacts"] = snapshot
	var inputs_variant = normalized.get("inputs", {})
	var inputs: Dictionary = {}
	if inputs_variant is Dictionary:
		inputs = (inputs_variant as Dictionary).duplicate(true)
	inputs["contact_impulse"] = maxf(0.0, float(snapshot.get("total_impulse", 0.0)))
	inputs["contact_velocity"] = maxf(0.0, float(snapshot.get("average_relative_speed", 0.0)))
	normalized["inputs"] = inputs
	return normalized

static func normalize_environment_stage_result(result, unknown_profile_id: String, unknown_phase_id: String) -> Dictionary:
	if result is Dictionary:
		var payload = result as Dictionary
		var dispatched = bool(payload.get("dispatched", false))
		if not dispatched and payload.get("execution", {}) is Dictionary:
			dispatched = bool((payload.get("execution", {}) as Dictionary).get("dispatched", false))
		var result_fields: Dictionary = {}
		if payload.get("result_fields", {}) is Dictionary:
			result_fields = (payload.get("result_fields", {}) as Dictionary)
		elif payload.get("result", {}) is Dictionary:
			result_fields = (payload.get("result", {}) as Dictionary)
			if result_fields.get("result_fields", {}) is Dictionary:
				result_fields = (result_fields.get("result_fields", {}) as Dictionary)
		elif payload.get("step_result", {}) is Dictionary:
			result_fields = (payload.get("step_result", {}) as Dictionary)
		elif payload.get("payload", {}) is Dictionary:
			result_fields = (payload.get("payload", {}) as Dictionary)
		if payload.get("physics_server_feedback", {}) is Dictionary:
			result_fields["physics_server_feedback"] = payload.get("physics_server_feedback", {})
		if payload.get("voxel_failure_emission", {}) is Dictionary:
			result_fields["voxel_failure_emission"] = payload.get("voxel_failure_emission", {})
		if payload.get("authoritative_mutation", {}) is Dictionary:
			result_fields["authoritative_mutation"] = payload.get("authoritative_mutation", {})
		if payload.get("pipeline", {}) is Dictionary:
			result_fields["pipeline"] = payload.get("pipeline", {})
		var result_inputs_variant = result_fields.get("inputs", {})
		var result_inputs: Dictionary = {}
		if result_inputs_variant is Dictionary:
			result_inputs = (result_inputs_variant as Dictionary).duplicate(true)
		var material_identity = material_identity_from_payload(result_fields, result_inputs, unknown_profile_id, unknown_phase_id)
		result_fields["material_identity"] = material_identity
		result_inputs["material_id"] = String(material_identity.get("material_id", "material:unknown")).strip_edges()
		result_inputs["material_profile_id"] = String(material_identity.get("material_profile_id", unknown_profile_id)).strip_edges()
		result_inputs["material_phase_id"] = String(material_identity.get("material_phase_id", unknown_phase_id)).strip_edges()
		result_inputs["element_id"] = String(material_identity.get("element_id", "element:unknown")).strip_edges()
		result_fields["inputs"] = result_inputs
		return {
			"ok": bool(payload.get("ok", true)),
			"executed": true,
			"dispatched": dispatched,
			"result": payload,
			"result_fields": result_fields,
			"error": String(payload.get("error", "")),
		}
	if result is bool:
		var bool_ok := bool(result)
		return {"ok": bool_ok, "executed": true, "dispatched": bool_ok, "result": result, "result_fields": {}, "error": "" if bool_ok else "dispatch_failed"}
	return {"ok": false, "executed": true, "dispatched": false, "result": result, "result_fields": {}, "error": "dispatch_failed"}

static func material_identity_from_payload(payload: Dictionary, inputs: Dictionary, unknown_profile_id: String, unknown_phase_id: String) -> Dictionary:
	var explicit_identity_variant = payload.get("material_identity", {})
	var explicit_identity: Dictionary = {}
	if explicit_identity_variant is Dictionary:
		explicit_identity = (explicit_identity_variant as Dictionary).duplicate(true)
	var material_id := String(explicit_identity.get("material_id", payload.get("material_id", inputs.get("material_id", "material:unknown")))).strip_edges()
	if material_id == "":
		material_id = "material:unknown"
	var material_profile_id := String(
		explicit_identity.get("material_profile_id", payload.get("material_profile_id", inputs.get("material_profile_id", unknown_profile_id)))
	).strip_edges()
	if material_profile_id == "":
		material_profile_id = unknown_profile_id
	var phase_source = explicit_identity.get(
		"material_phase_id",
		payload.get("material_phase_id", inputs.get("material_phase_id", payload.get("phase", inputs.get("phase", unknown_phase_id))))
	)
	var material_phase_id := canonical_phase_id_from_value(phase_source, unknown_phase_id)
	if material_phase_id == "":
		material_phase_id = unknown_phase_id
	var element_id := String(explicit_identity.get("element_id", payload.get("element_id", inputs.get("element_id", "element:unknown")))).strip_edges()
	if element_id == "":
		element_id = "element:unknown"
	return {
		"material_id": material_id,
		"material_profile_id": material_profile_id,
		"material_phase_id": material_phase_id,
		"element_id": element_id,
	}

static func canonical_phase_id_from_value(raw_value, unknown_phase_id: String) -> String:
	if raw_value is String:
		var raw_string := String(raw_value).strip_edges().to_lower()
		if raw_string == "":
			return unknown_phase_id
		if raw_string.begins_with("phase:"):
			return raw_string
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
			return unknown_phase_id
