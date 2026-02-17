extends RefCounted
class_name LocalAgentsDebrisContactReporter

const PhysicsServerContactBridgeScript = preload("res://addons/local_agents/simulation/controller/PhysicsServerContactBridge.gd")

const _DEBRIS_ROOT_NAME := "NativeFractureDebrisRoot"
const _VOXEL_CONTACT_GROUP := "local_agents_voxel_contact_dispatch"
const _CONTACT_RECENT_CAPACITY := 512
const _CONTACT_REPEAT_COOLDOWN_FRAMES := 2
const _DEFAULT_PROJECTILE_KIND := "voxel_chunk"
const _DEFAULT_PROJECTILE_DENSITY_TAG := "dense"
const _DEFAULT_PROJECTILE_HARDNESS_TAG := "hard"
const _DEFAULT_FAILURE_EMISSION_PROFILE := "dense_hard_voxel_chunk"
const _DEFAULT_PROJECTILE_MATERIAL_TAG := "dense_voxel"
const _DEFAULT_PROJECTILE_RADIUS := 0.07
const _DEFAULT_PROJECTILE_BODY_MASS := 0.2
const _DEFAULT_MUTATION_DEADLINE_FRAMES := 6

var _recent_contact_frames: Dictionary = {}
var _recent_contact_order: Array[String] = []

func sample_contact_rows(simulation_root: Node, frame_index: int) -> Array:
	if simulation_root == null:
		return []
	var candidates := _collect_contact_candidates(simulation_root)
	if candidates.is_empty():
		return []
	var sampled_rows := PhysicsServerContactBridgeScript.sample_contact_rows(candidates)
	if sampled_rows.is_empty():
		return []
	var normalized_rows: Array = []
	var frame := maxi(0, frame_index)
	var debris_root := simulation_root.get_node_or_null(_DEBRIS_ROOT_NAME)
	for row_variant in sampled_rows:
		if not (row_variant is Dictionary):
			continue
		var row: Dictionary = (row_variant as Dictionary).duplicate(true)
		var key := _row_key(row)
		var last_frame := int(_recent_contact_frames.get(key, -1000000))
		if frame - last_frame <= _CONTACT_REPEAT_COOLDOWN_FRAMES:
			continue
		_recent_contact_frames[key] = frame
		_recent_contact_order.append(key)
		_trim_recent_cache_if_needed()
		normalized_rows.append(_normalize_dispatch_row(row, frame, debris_root))
	return normalized_rows

func sample_debris_contact_rows(simulation_root: Node, frame_index: int) -> Array:
	return sample_contact_rows(simulation_root, frame_index)

func _collect_contact_candidates(simulation_root: Node) -> Array:
	var candidates: Array = []
	var debris_root := simulation_root.get_node_or_null(_DEBRIS_ROOT_NAME)
	if debris_root != null:
		candidates.append(debris_root)
	var tree := simulation_root.get_tree()
	if tree == null:
		return candidates
	for node_variant in tree.get_nodes_in_group(_VOXEL_CONTACT_GROUP):
		if not (node_variant is Node):
			continue
		var node := node_variant as Node
		if node == null or not simulation_root.is_ancestor_of(node):
			continue
		candidates.append(node)
	return candidates

func _resolve_contact_source(row: Dictionary, debris_root: Node) -> String:
	var body_id := int(row.get("body_id", 0))
	var collider_id := int(row.get("collider_id", 0))
	if _is_node_under(debris_root, instance_from_id(body_id)) or _is_node_under(debris_root, instance_from_id(collider_id)):
		return "fracture_debris"
	return "fracture_dynamic"

func _is_node_under(root: Node, node_variant: Variant) -> bool:
	if root == null:
		return false
	if not (node_variant is Node):
		return false
	var node := node_variant as Node
	return node == root or root.is_ancestor_of(node)

func _normalize_dispatch_row(row: Dictionary, frame: int, debris_root: Node) -> Dictionary:
	var normalized := row.duplicate(true)
	normalized["contact_source"] = _resolve_contact_source(normalized, debris_root)
	normalized["projectile_kind"] = String(normalized.get("projectile_kind", _DEFAULT_PROJECTILE_KIND))
	normalized["projectile_density_tag"] = String(normalized.get("projectile_density_tag", _DEFAULT_PROJECTILE_DENSITY_TAG))
	normalized["projectile_hardness_tag"] = String(normalized.get("projectile_hardness_tag", _DEFAULT_PROJECTILE_HARDNESS_TAG))
	normalized["failure_emission_profile"] = String(normalized.get("failure_emission_profile", _DEFAULT_FAILURE_EMISSION_PROFILE))
	normalized["projectile_material_tag"] = String(normalized.get("projectile_material_tag", _DEFAULT_PROJECTILE_MATERIAL_TAG))
	normalized["projectile_radius"] = maxf(0.0, float(normalized.get("projectile_radius", _DEFAULT_PROJECTILE_RADIUS)))
	normalized["body_mass"] = maxf(0.01, float(normalized.get("body_mass", _DEFAULT_PROJECTILE_BODY_MASS)))
	var deadline := int(normalized.get("deadline_frame", -1))
	if deadline < 0:
		deadline = frame + _DEFAULT_MUTATION_DEADLINE_FRAMES
	normalized["deadline_frame"] = deadline
	return normalized

func _trim_recent_cache_if_needed() -> void:
	while _recent_contact_order.size() > _CONTACT_RECENT_CAPACITY:
		var stale_key := _recent_contact_order.pop_front()
		if stale_key != "":
			_recent_contact_frames.erase(stale_key)

func _row_key(row: Dictionary) -> String:
	var body_id := int(row.get("body_id", 0))
	var collider_id := int(row.get("collider_id", 0))
	var point_raw: Variant = row.get("contact_point", Vector3.ZERO)
	var point: Vector3 = point_raw if point_raw is Vector3 else Vector3.ZERO
	var point_qx := int(round(point.x * 20.0))
	var point_qy := int(round(point.y * 20.0))
	var point_qz := int(round(point.z * 20.0))
	return "%d|%d|%d|%d|%d" % [body_id, collider_id, point_qx, point_qy, point_qz]
