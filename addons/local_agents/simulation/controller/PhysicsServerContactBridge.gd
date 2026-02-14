extends RefCounted

const _EMPTY_SAMPLE := {
	"body_id": 0,
	"collider_id": 0,
	"contact_point": Vector3.ZERO,
	"contact_normal": Vector3.ZERO,
	"contact_impulse": 0.0,
	"contact_velocity": 0.0,
	"body_velocity": Vector3.ZERO,
	"body_mass": 0.0,
	"collider_mass": 0.0,
	"obstacle_velocity": Vector3.ZERO,
	"obstacle_trajectory": Vector3.ZERO,
	"rigid_obstacle_mask": 0,
}


static func sample_contact_rows(candidates: Array) -> Array:
	var bodies := _collect_collision_bodies(candidates)
	var rows: Array = []
	for body in bodies:
		if not is_instance_valid(body):
			continue
		rows.append_array(_sample_body_contacts(body))
	rows.sort_custom(_sort_contact_rows)
	return rows


static func summarize_contact_rows(rows: Array) -> Dictionary:
	var impulse_sum := 0.0
	var max_impulse := 0.0
	var normal_y_sum := 0.0
	var contact_count := 0
	for row_variant in rows:
		if not (row_variant is Dictionary):
			continue
		var row: Dictionary = row_variant
		var impulse := float(row.get("contact_impulse", 0.0))
		var normal := _vector3_or_zero(row.get("contact_normal", Vector3.ZERO))
		impulse_sum += impulse
		normal_y_sum += normal.y
		if impulse > max_impulse:
			max_impulse = impulse
		contact_count += 1
	var avg_normal_y := 0.0
	if contact_count > 0:
		avg_normal_y = normal_y_sum / float(contact_count)
	return {
		"impulse_sum": impulse_sum,
		"contact_count": contact_count,
		"avg_normal_y": avg_normal_y,
		"max_impulse": max_impulse,
	}


static func sample_with_summary(candidates: Array) -> Dictionary:
	var rows := sample_contact_rows(candidates)
	var summary := summarize_contact_rows(rows)
	summary["rows"] = rows
	return summary


static func _collect_collision_bodies(candidates: Array) -> Array:
	var seen: Dictionary = {}
	var out: Array = []
	for candidate in candidates:
		_collect_candidate_bodies(candidate, seen, out)
	out.sort_custom(_sort_nodes_by_instance_id)
	return out


static func _collect_candidate_bodies(candidate, seen: Dictionary, out: Array) -> void:
	if candidate == null:
		return
	if candidate is CollisionObject3D:
		_append_unique_body(candidate as CollisionObject3D, seen, out)
		return
	if not (candidate is Node3D):
		return
	var root := candidate as Node3D
	var stack: Array = [root]
	while not stack.is_empty():
		var current_variant = stack.pop_back()
		if not (current_variant is Node):
			continue
		var current: Node = current_variant
		if current is CollisionObject3D:
			_append_unique_body(current as CollisionObject3D, seen, out)
		var child_count := current.get_child_count()
		for child_index in child_count:
			stack.push_back(current.get_child(child_index))


static func _append_unique_body(body: CollisionObject3D, seen: Dictionary, out: Array) -> void:
	if not is_instance_valid(body):
		return
	var id := body.get_instance_id()
	if id <= 0 or seen.has(id):
		return
	seen[id] = true
	out.append(body)


static func _sample_body_contacts(body: CollisionObject3D) -> Array:
	var rows: Array = []
	var rid := body.get_rid()
	if not rid.is_valid():
		return rows
	if not ClassDB.class_has_method("PhysicsServer3D", "body_get_direct_state"):
		return rows
	var state = PhysicsServer3D.body_get_direct_state(rid)
	if state == null:
		return rows
	if not state.has_method("get_contact_count"):
		return rows
	var contact_count := int(state.call("get_contact_count"))
	if contact_count <= 0:
		return rows
	var body_velocity := _sample_body_velocity(body, state)
	var body_id := body.get_instance_id()
	var basis := body.global_transform.basis
	var obstacle_trajectory := Vector3.ZERO
	var body_velocity_scalar := body_velocity.length()
	if body_velocity.length_squared() > 0.0:
		obstacle_trajectory = body_velocity.normalized()
	for index in contact_count:
		var row := _EMPTY_SAMPLE.duplicate(true)
		row["body_id"] = body_id
		var collider_id := _sample_collider_id(state, index)
		row["collider_id"] = collider_id
		row["contact_point"] = _sample_contact_point(body, state, index)
		row["contact_normal"] = _sample_contact_normal(state, basis, index)
		row["contact_impulse"] = _sample_contact_impulse(state, index)
		row["body_velocity"] = body_velocity
		row["obstacle_velocity"] = body_velocity
		row["obstacle_trajectory"] = obstacle_trajectory
		row["body_mass"] = _sample_body_mass(body)
		row["collider_mass"] = _sample_body_mass(instance_from_id(collider_id))
		row["contact_velocity"] = body_velocity_scalar
		row["rigid_obstacle_mask"] = _sample_rigid_obstacle_mask(collider_id)
		rows.append(row)
	return rows


static func _sample_body_velocity(body: CollisionObject3D, state) -> Vector3:
	if state != null and state.has_method("get_linear_velocity"):
		var velocity_variant = state.call("get_linear_velocity")
		if velocity_variant is Vector3:
			return velocity_variant
	if body.has_method("get_linear_velocity"):
		var body_velocity = body.call("get_linear_velocity")
		if body_velocity is Vector3:
			return body_velocity
	return Vector3.ZERO


static func _sample_body_mass(body_variant) -> float:
	if body_variant == null or not (body_variant is Object):
		return 0.0
	var body := body_variant as Object
	if body.has_method("get_mass"):
		var mass_variant = body.call("get_mass")
		if mass_variant is float or mass_variant is int:
			return maxf(0.0, float(mass_variant))
	if body.has_method("get_total_mass"):
		var mass_variant = body.call("get_total_mass")
		if mass_variant is float or mass_variant is int:
			return maxf(0.0, float(mass_variant))
	return 0.0


static func _sample_collider_id(state, contact_index: int) -> int:
	if state == null:
		return 0
	if state.has_method("get_contact_collider_id"):
		return int(state.call("get_contact_collider_id", contact_index))
	if state.has_method("get_contact_collider_object"):
		var obj_variant = state.call("get_contact_collider_object", contact_index)
		if obj_variant is Object:
			return (obj_variant as Object).get_instance_id()
	if state.has_method("get_contact_collider"):
		var collider_variant = state.call("get_contact_collider", contact_index)
		if collider_variant is Object:
			return (collider_variant as Object).get_instance_id()
	return 0


static func _sample_contact_point(body: CollisionObject3D, state, contact_index: int) -> Vector3:
	if state == null:
		return Vector3.ZERO
	if state.has_method("get_contact_collider_position"):
		return _vector3_or_zero(state.call("get_contact_collider_position", contact_index))
	if state.has_method("get_contact_local_position"):
		var local_point := _vector3_or_zero(state.call("get_contact_local_position", contact_index))
		return body.global_transform * local_point
	return Vector3.ZERO


static func _sample_contact_normal(state, basis: Basis, contact_index: int) -> Vector3:
	if state == null:
		return Vector3.ZERO
	if state.has_method("get_contact_collider_normal"):
		return _normalize_vector3(_vector3_or_zero(state.call("get_contact_collider_normal", contact_index)))
	if state.has_method("get_contact_local_normal"):
		var local_normal := _vector3_or_zero(state.call("get_contact_local_normal", contact_index))
		return _normalize_vector3((basis * local_normal))
	return Vector3.ZERO


static func _sample_contact_impulse(state, contact_index: int) -> float:
	if state == null:
		return 0.0
	if state.has_method("get_contact_impulse"):
		return maxf(0.0, float(state.call("get_contact_impulse", contact_index)))
	return 0.0


static func _sample_rigid_obstacle_mask(collider_id: int) -> int:
	if collider_id <= 0:
		return 0
	var collider_obj = instance_from_id(collider_id)
	if not (collider_obj is CollisionObject3D):
		return 0
	var collider := collider_obj as CollisionObject3D
	if collider.has_method("get_collision_layer"):
		return int(collider.call("get_collision_layer"))
	return 0


static func _vector3_or_zero(value) -> Vector3:
	if value is Vector3:
		return value
	return Vector3.ZERO


static func _normalize_vector3(value: Vector3) -> Vector3:
	if value.length_squared() <= 0.0:
		return Vector3.ZERO
	return value.normalized()


static func _sort_nodes_by_instance_id(a, b) -> bool:
	if a == null:
		return false
	if b == null:
		return true
	if not (a is Object) or not (b is Object):
		return false
	return (a as Object).get_instance_id() < (b as Object).get_instance_id()


static func _sort_contact_rows(a, b) -> bool:
	if not (a is Dictionary) or not (b is Dictionary):
		return false
	var left: Dictionary = a
	var right: Dictionary = b
	var left_body := int(left.get("body_id", 0))
	var right_body := int(right.get("body_id", 0))
	if left_body != right_body:
		return left_body < right_body
	var left_collider := int(left.get("collider_id", 0))
	var right_collider := int(right.get("collider_id", 0))
	if left_collider != right_collider:
		return left_collider < right_collider
	var left_impulse := float(left.get("contact_impulse", 0.0))
	var right_impulse := float(right.get("contact_impulse", 0.0))
	if not is_equal_approx(left_impulse, right_impulse):
		return left_impulse < right_impulse
	var left_point := _vector3_or_zero(left.get("contact_point", Vector3.ZERO))
	var right_point := _vector3_or_zero(right.get("contact_point", Vector3.ZERO))
	if not is_equal_approx(left_point.x, right_point.x):
		return left_point.x < right_point.x
	if not is_equal_approx(left_point.y, right_point.y):
		return left_point.y < right_point.y
	if not is_equal_approx(left_point.z, right_point.z):
		return left_point.z < right_point.z
	return false
