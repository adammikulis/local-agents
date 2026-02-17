extends RefCounted
class_name LocalAgentsNativeComputeBridgeContactNormalization

const PhysicsServerContactBridgeScript = preload("res://addons/local_agents/simulation/controller/PhysicsServerContactBridge.gd")

static func normalize_physics_contacts_from_payload(payload: Dictionary) -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	for key in ["physics_server_contacts", "physics_contacts", "contact_samples"]:
		var samples = payload.get(key, [])
		if not (samples is Array):
			continue
		for sample in samples:
			if not (sample is Dictionary):
				continue
			rows.append(normalize_contact_row(sample as Dictionary))
	if rows.is_empty():
		var candidates_variant = payload.get("physics_contact_candidates", payload.get("contact_candidates", []))
		if candidates_variant is Array:
			for sample in PhysicsServerContactBridgeScript.sample_contact_rows(candidates_variant as Array):
				if sample is Dictionary:
					rows.append(normalize_contact_row(sample as Dictionary))
	return rows

static func normalize_contact_row(row: Dictionary) -> Dictionary:
	var normalized: Dictionary = {}
	for key in row.keys():
		normalized[key] = row.get(key)

	var impulse = maxf(0.0, read_float(row, ["contact_impulse", "impulse", "normal_impulse"], 0.0))
	var normal := read_vector3_from_keys(row, ["contact_normal", "normal", "collision_normal"]).normalized()
	var point := read_vector3_from_keys(row, ["contact_point", "point", "position"])
	var velocity_raw = row.get("body_velocity", row.get("linear_velocity", row.get("velocity", 0.0)))
	var velocity = read_contact_velocity(velocity_raw)
	var obstacle_velocity = read_contact_velocity(row.get("obstacle_velocity", row.get("motion_speed", 0.0)))
	var body_mass = maxf(0.0, read_float(row, ["body_mass", "mass"], 0.0))
	var collider_mass = maxf(0.0, read_float(row, ["collider_mass"], 0.0))
	var row_contact_velocity = read_contact_velocity(row.get("contact_velocity", 0.0))
	var row_relative_speed = read_contact_velocity(row.get("relative_speed", 0.0))
	if row_contact_velocity <= 0.0:
		row_contact_velocity = maxf(row_relative_speed, absf(velocity - obstacle_velocity))
	var relative_speed = maxf(row_contact_velocity, maxf(row_relative_speed, absf(velocity - obstacle_velocity)))
	var obstacle_trajectory = read_vector3_from_keys(row, ["obstacle_trajectory", "motion_trajectory", "trajectory"])
	normalized["contact_impulse"] = impulse
	normalized["impulse"] = impulse
	normalized["contact_velocity"] = row_contact_velocity
	normalized["relative_speed"] = relative_speed
	normalized["contact_normal"] = normal
	normalized["contact_point"] = point
	normalized["body_velocity"] = velocity
	normalized["obstacle_velocity"] = obstacle_velocity
	normalized["body_mass"] = body_mass
	normalized["collider_mass"] = collider_mass
	normalized["obstacle_trajectory"] = obstacle_trajectory
	normalized["body_id"] = int(read_float(row, ["body_id", "id", "rid"], -1.0))
	normalized["rigid_obstacle_mask"] = maxi(int(read_float(row, ["rigid_obstacle_mask", "obstacle_mask", "collision_mask", "collision_layer"], 0.0)), 0)
	return normalized

static func aggregate_contact_inputs(rows: Array[Dictionary]) -> Dictionary:
	var deterministic_rows := rows.duplicate(true)
	deterministic_rows.sort_custom(sort_aggregated_contact_rows)
	var total_impulse := 0.0
	var normal_sum := Vector3.ZERO
	var contact_velocity_sum := 0.0
	var point_sum := Vector3.ZERO
	var velocity_sum := 0.0
	var obstacle_velocity_sum := 0.0
	var obstacle_trajectory_sum := Vector3.ZERO
	var body_mass_sum := 0.0
	var collider_mass_sum := 0.0
	var strongest_impulse := -1.0
	var strongest_id := -1
	var strongest_mask := 0
	for row in deterministic_rows:
		var impulse = maxf(float(row.get("contact_impulse", 0.0)), 0.0)
		var weight = impulse if impulse > 0.0 else 1.0
		total_impulse += impulse
		normal_sum += read_vector3(row.get("contact_normal", Vector3.ZERO)) * weight
		point_sum += read_vector3(row.get("contact_point", Vector3.ZERO)) * weight
		velocity_sum += maxf(float(row.get("body_velocity", 0.0)), 0.0) * weight
		var row_obstacle_velocity = maxf(read_contact_velocity(row.get("obstacle_velocity", 0.0)), 0.0)
		obstacle_velocity_sum += row_obstacle_velocity * weight
		obstacle_trajectory_sum += read_vector3(row.get("obstacle_trajectory", Vector3.ZERO)) * weight
		contact_velocity_sum += maxf(read_contact_velocity(row.get("contact_velocity", 0.0)), 0.0) * weight
		body_mass_sum += maxf(float(row.get("body_mass", 0.0)), 0.0) * weight
		collider_mass_sum += maxf(float(row.get("collider_mass", 0.0)), 0.0) * weight
		if impulse > strongest_impulse:
			strongest_impulse = impulse
			strongest_id = int(row.get("body_id", -1))
			strongest_mask = maxi(int(row.get("rigid_obstacle_mask", 0)), 0)
	var weight_total = total_impulse if total_impulse > 0.0 else float(rows.size())
	var avg_normal := normal_sum / maxf(weight_total, 1.0)
	if avg_normal.length_squared() > 0.0:
		avg_normal = avg_normal.normalized()
	return {
		"contact_impulse": total_impulse,
		"contact_velocity": contact_velocity_sum / maxf(weight_total, 1.0),
		"contact_normal": avg_normal,
		"contact_point": point_sum / maxf(weight_total, 1.0),
		"body_velocity": velocity_sum / maxf(weight_total, 1.0),
		"obstacle_velocity": obstacle_velocity_sum / maxf(weight_total, 1.0),
		"body_mass": body_mass_sum / maxf(weight_total, 1.0),
		"collider_mass": collider_mass_sum / maxf(weight_total, 1.0),
		"obstacle_trajectory": obstacle_trajectory_sum / maxf(weight_total, 1.0),
		"body_id": strongest_id,
		"rigid_obstacle_mask": strongest_mask,
	}

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
	var left_impulse := float(left.get("contact_impulse", 0.0))
	var right_impulse := float(right.get("contact_impulse", 0.0))
	if not is_equal_approx(left_impulse, right_impulse):
		return left_impulse < right_impulse
	var left_velocity := read_contact_velocity(left.get("body_velocity", 0.0))
	var right_velocity := read_contact_velocity(right.get("body_velocity", 0.0))
	if not is_equal_approx(left_velocity, right_velocity):
		return left_velocity < right_velocity
	var left_obstacle_velocity := read_contact_velocity(left.get("obstacle_velocity", 0.0))
	var right_obstacle_velocity := read_contact_velocity(right.get("obstacle_velocity", 0.0))
	if not is_equal_approx(left_obstacle_velocity, right_obstacle_velocity):
		return left_obstacle_velocity < right_obstacle_velocity
	var left_obstacle_trajectory := read_vector3(left.get("obstacle_trajectory", Vector3.ZERO))
	var right_obstacle_trajectory := read_vector3(right.get("obstacle_trajectory", Vector3.ZERO))
	if not is_equal_approx(left_obstacle_trajectory.x, right_obstacle_trajectory.x):
		return left_obstacle_trajectory.x < right_obstacle_trajectory.x
	if not is_equal_approx(left_obstacle_trajectory.y, right_obstacle_trajectory.y):
		return left_obstacle_trajectory.y < right_obstacle_trajectory.y
	if not is_equal_approx(left_obstacle_trajectory.z, right_obstacle_trajectory.z):
		return left_obstacle_trajectory.z < right_obstacle_trajectory.z
	var left_normal := read_vector3(left.get("contact_normal", Vector3.ZERO))
	var right_normal := read_vector3(right.get("contact_normal", Vector3.ZERO))
	if not is_equal_approx(left_normal.x, right_normal.x):
		return left_normal.x < right_normal.x
	if not is_equal_approx(left_normal.y, right_normal.y):
		return left_normal.y < right_normal.y
	if not is_equal_approx(left_normal.z, right_normal.z):
		return left_normal.z < right_normal.z
	var left_point := read_vector3(left.get("contact_point", Vector3.ZERO))
	var right_point := read_vector3(right.get("contact_point", Vector3.ZERO))
	if not is_equal_approx(left_point.x, right_point.x):
		return left_point.x < right_point.x
	if not is_equal_approx(left_point.y, right_point.y):
		return left_point.y < right_point.y
	if not is_equal_approx(left_point.z, right_point.z):
		return left_point.z < right_point.z
	return false

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
