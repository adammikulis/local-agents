extends RefCounted
class_name LocalAgentsNativeComputeBridgeContactNormalization

const PhysicsServerContactBridgeScript = preload("res://addons/local_agents/simulation/controller/PhysicsServerContactBridge.gd")
const ExtensionLoaderScript = preload("res://addons/local_agents/runtime/LocalAgentsExtensionLoader.gd")
const NATIVE_SIM_CORE_SINGLETON_NAME := "LocalAgentsSimulationCore"
const _NATIVE_CONTACT_SERIALIZER_FAILED := "native_contact_serializer_failed"

static func normalize_physics_contacts_from_payload(payload: Dictionary) -> Array[Dictionary]:
	var contract := normalize_physics_contacts_contract(payload)
	var rows_variant = contract.get("rows", [])
	var rows: Array[Dictionary] = []
	if rows_variant is Array:
		for row_variant in (rows_variant as Array):
			if row_variant is Dictionary:
				rows.append((row_variant as Dictionary).duplicate(true))
	return rows

static func normalize_physics_contacts_contract(payload: Dictionary) -> Dictionary:
	var raw_rows: Array = []
	for key in ["physics_server_contacts", "physics_contacts", "contact_samples"]:
		var samples = payload.get(key, [])
		if not (samples is Array):
			continue
		for sample in (samples as Array):
			if sample is Dictionary:
				raw_rows.append((sample as Dictionary).duplicate(true))
	if raw_rows.is_empty():
		var candidates_variant = payload.get("physics_contact_candidates", payload.get("contact_candidates", []))
		if candidates_variant is Array:
			for sample in PhysicsServerContactBridgeScript.sample_contact_rows(candidates_variant as Array):
				if sample is Dictionary:
					raw_rows.append((sample as Dictionary).duplicate(true))
	return _normalize_rows_contract_via_native_serializer(raw_rows)

static func normalize_contact_row(row: Dictionary) -> Dictionary:
	if row.is_empty():
		return {}
	var normalized_rows := _normalize_rows_via_native_serializer([row])
	if normalized_rows.is_empty():
		return {}
	return normalized_rows[0].duplicate(true)

static func aggregate_contact_inputs(rows: Array[Dictionary]) -> Dictionary:
	var payload := _normalize_and_aggregate_via_native(rows)
	var aggregated_variant = payload.get("aggregated_inputs", {})
	if aggregated_variant is Dictionary:
		return (aggregated_variant as Dictionary).duplicate(true)
	return {}

static func sort_aggregated_contact_rows(left_variant, right_variant) -> bool:
	if not (left_variant is Dictionary) or not (right_variant is Dictionary):
		return false
	var left: Dictionary = left_variant
	var right: Dictionary = right_variant
	var left_body := int(left.get("body_id", 0))
	var right_body := int(right.get("body_id", 0))
	if left_body != right_body:
		return left_body < right_body
	var left_mask := int(left.get("rigid_obstacle_mask", 0))
	var right_mask := int(right.get("rigid_obstacle_mask", 0))
	if left_mask != right_mask:
		return left_mask < right_mask
	return float(left.get("contact_impulse", 0.0)) < float(right.get("contact_impulse", 0.0))

static func read_contact_velocity(raw_value) -> float:
	if raw_value is Vector2 or raw_value is Vector3 or raw_value is Array or raw_value is Dictionary:
		return read_vector3(raw_value).length()
	return maxf(0.0, float(raw_value))

static func read_float(row: Dictionary, keys: Array, fallback: float) -> float:
	for key_variant in keys:
		var key := String(key_variant)
		if row.has(key):
			return float(row.get(key, fallback))
	return fallback

static func read_vector3_from_keys(row: Dictionary, keys: Array) -> Vector3:
	for key_variant in keys:
		var key := String(key_variant)
		if row.has(key):
			return read_vector3(row.get(key))
	return Vector3.ZERO

static func read_vector3(raw_value) -> Vector3:
	if raw_value is Vector3:
		return raw_value as Vector3
	if raw_value is Vector2:
		var vec2 := raw_value as Vector2
		return Vector3(vec2.x, vec2.y, 0.0)
	if raw_value is Array:
		var arr = raw_value as Array
		if arr.size() >= 3:
			return Vector3(float(arr[0]), float(arr[1]), float(arr[2]))
		if arr.size() == 2:
			return Vector3(float(arr[0]), float(arr[1]), 0.0)
		return Vector3.ZERO
	if raw_value is Dictionary:
		var row = raw_value as Dictionary
		return Vector3(float(row.get("x", 0.0)), float(row.get("y", 0.0)), float(row.get("z", 0.0)))
	return Vector3.ZERO

static func _normalize_rows_via_native_serializer(raw_rows: Array) -> Array[Dictionary]:
	var contract := _normalize_rows_contract_via_native_serializer(raw_rows)
	var normalized_variant = contract.get("rows", [])
	var normalized_rows: Array[Dictionary] = []
	if normalized_variant is Array:
		for row_variant in (normalized_variant as Array):
			if row_variant is Dictionary:
				normalized_rows.append((row_variant as Dictionary).duplicate(true))
	return normalized_rows

static func _normalize_rows_contract_via_native_serializer(raw_rows: Array) -> Dictionary:
	var payload := _normalize_and_aggregate_via_native(raw_rows)
	var serializer_ok := bool(payload.get("ok", false))
	if not serializer_ok:
		var error_code := String(payload.get("error", _NATIVE_CONTACT_SERIALIZER_FAILED)).strip_edges()
		if error_code == "":
			error_code = _NATIVE_CONTACT_SERIALIZER_FAILED
		push_error("NATIVE_REQUIRED: %s" % error_code)
		return {
			"ok": false,
			"error": error_code,
			"rows": [],
			"row_count": 0,
		}
	var normalized_variant = payload.get("normalized_rows", [])
	var normalized_rows: Array = []
	if normalized_variant is Array:
		normalized_rows = (normalized_variant as Array).duplicate(true)
	return {
		"ok": true,
		"error": "",
		"rows": normalized_rows,
		"row_count": int(payload.get("row_count", normalized_rows.size())),
	}

static func _normalize_and_aggregate_via_native(contact_rows: Array) -> Dictionary:
	var core = _resolve_native_sim_core()
	if core == null or not core.has_method("normalize_and_aggregate_physics_contacts"):
		return {
			"ok": false,
			"error": "native_contact_serializer_unavailable",
			"normalized_rows": [],
			"aggregated_inputs": {},
			"row_count": 0,
		}
	var result_variant = core.call("normalize_and_aggregate_physics_contacts", contact_rows)
	if result_variant is Dictionary:
		return (result_variant as Dictionary).duplicate(true)
	return {
		"ok": false,
		"error": "native_contact_serializer_invalid_result",
		"normalized_rows": [],
		"aggregated_inputs": {},
		"row_count": 0,
	}

static func _resolve_native_sim_core() -> Object:
	ExtensionLoaderScript.ensure_initialized()
	if Engine.has_singleton(NATIVE_SIM_CORE_SINGLETON_NAME):
		var singleton = Engine.get_singleton(NATIVE_SIM_CORE_SINGLETON_NAME)
		if singleton != null:
			return singleton
	if ClassDB.class_exists(NATIVE_SIM_CORE_SINGLETON_NAME):
		var instance = ClassDB.instantiate(NATIVE_SIM_CORE_SINGLETON_NAME)
		if instance != null:
			return instance
	return null
