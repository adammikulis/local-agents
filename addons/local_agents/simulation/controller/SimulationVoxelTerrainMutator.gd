extends RefCounted
class_name LocalAgentsSimulationVoxelTerrainMutator

const TileKeyUtilsScript = preload("res://addons/local_agents/simulation/TileKeyUtils.gd")
const ContactTileResolverScript = preload("res://addons/local_agents/simulation/controller/SimulationVoxelContactTileResolver.gd")

const _WALL_FORWARD_DISTANCE_METERS := 9.0
const _WALL_HALF_SPAN_TILES := 4
const _WALL_HEIGHT_LEVELS := 6
const _WALL_THICKNESS_TILES := 1
const _WALL_COLUMN_SPAN_INTERVAL := 3
const _WALL_COLUMN_EXTRA_LEVELS := 4
const _WALL_COLUMN_DESTRUCTIBLE_TAG := "target_wall"
const _WALL_COLUMN_MATERIAL_PROFILE_KEY := "rock"
const _WALL_COLUMN_BRITTLENESS := 1.0
const _WALL_PILLAR_HEIGHT_SCALE := 1.0
const _WALL_PILLAR_DENSITY_SCALE := 1.0
const _NATIVE_OP_VALUE_TO_LEVELS := 3.0
const _NATIVE_OP_MAX_LEVELS := 6
const _PATH_INVALID_CONTROLLER := "stage_invalid_controller"
const _PATH_CONTACT_FALLBACK_PRE_OPS := "contact_confirmed_column_fallback_pre_ops"
const _PATH_CHANGED_REGION_FALLBACK := "changed_region_column_fallback"
const _PATH_NO_OP_PAYLOAD := "native_voxel_op_payload_missing"
const _PATH_NATIVE_OPS_PRIMARY := "native_ops_payload_primary"
const _PATH_DIRECT_IMPACT_OP_FALLBACK := "direct_impact_ops_payload_fallback"
const _PATH_CONTACT_FALLBACK_POST_OPS := "contact_confirmed_column_fallback_post_ops"
const _PATH_STAGE_NO_MUTATION := "native_voxel_stage_no_mutation"

static func stamp_default_target_wall(controller, tick: int, camera_transform: Transform3D, target_wall_profile = null) -> Dictionary:
	if controller == null:
		return {"ok": false, "changed": false, "error": "invalid_controller", "tick": tick}
	var env_snapshot = controller._environment_snapshot.duplicate(true)
	if env_snapshot.is_empty():
		return {"ok": true, "changed": false, "error": "", "tick": tick}
	var width := int(env_snapshot.get("width", 0))
	var height := int(env_snapshot.get("height", 0))
	if width <= 0 or height <= 0:
		return {"ok": true, "changed": false, "error": "", "tick": tick}
	var forward := -camera_transform.basis.z
	forward.y = 0.0
	if forward.length_squared() <= 0.0001:
		forward = Vector3(0.0, 0.0, -1.0)
	forward = forward.normalized()
	var anchor_x := clampi(int(round(camera_transform.origin.x + forward.x * _WALL_FORWARD_DISTANCE_METERS)), 0, width - 1)
	var anchor_z := clampi(int(round(camera_transform.origin.z + forward.z * _WALL_FORWARD_DISTANCE_METERS)), 0, height - 1)
	var axis_z_dominant := absf(forward.z) >= absf(forward.x)
	var profile = _resolve_target_wall_profile(target_wall_profile)
	var wall_height_levels := int(profile.get("wall_height_levels", _WALL_HEIGHT_LEVELS))
	var column_span_interval := int(profile.get("column_span_interval", _WALL_COLUMN_SPAN_INTERVAL))
	var column_extra_levels := int(profile.get("column_extra_levels", _WALL_COLUMN_EXTRA_LEVELS))
	var destructible_tag := String(profile.get("destructible_tag", _WALL_COLUMN_DESTRUCTIBLE_TAG))
	var material_profile_key := String(profile.get("material_profile_key", _WALL_COLUMN_MATERIAL_PROFILE_KEY))
	var brittleness := float(profile.get("brittleness", _WALL_COLUMN_BRITTLENESS))
	var pillar_height_scale := clampf(float(profile.get("pillar_height_scale", _WALL_PILLAR_HEIGHT_SCALE)), 0.25, 3.0)
	var pillar_density_scale := clampf(float(profile.get("pillar_density_scale", _WALL_PILLAR_DENSITY_SCALE)), 0.25, 3.0)
	var effective_column_span_interval := maxi(1, int(round(float(column_span_interval) / pillar_density_scale)))
	var effective_column_extra_levels := maxi(0, int(round(float(column_extra_levels) * pillar_height_scale)))
	var structural_strength_scale := _strength_scale_for_brittleness(brittleness)
	var changed_tiles_map: Dictionary = {}
	var tile_height_overrides: Dictionary = {}
	var tile_column_metadata_overrides: Dictionary = {}
	for span in range(-_WALL_HALF_SPAN_TILES, _WALL_HALF_SPAN_TILES + 1):
		for depth in range(0, _WALL_THICKNESS_TILES):
			var tx := anchor_x
			var tz := anchor_z
			if axis_z_dominant:
				tx += span
				tz += depth
			else:
				tx += depth
				tz += span
			if tx < 0 or tx >= width or tz < 0 or tz >= height:
				continue
			var tile_id = TileKeyUtilsScript.tile_id(tx, tz)
			changed_tiles_map[tile_id] = true
			var column_height_levels := wall_height_levels
			if depth == 0 and abs(span) % effective_column_span_interval == 0:
				column_height_levels += effective_column_extra_levels
			tile_height_overrides[tile_id] = column_height_levels
			tile_column_metadata_overrides[tile_id] = {
				"destructible": true,
				"destructible_tag": destructible_tag,
				"material_profile_key": material_profile_key,
				"brittleness": brittleness,
				"structural_strength_scale": structural_strength_scale,
				"fracture_threshold_scale": structural_strength_scale,
			}
	var result = _apply_column_surface_delta(
		controller,
		env_snapshot,
		changed_tiles_map.keys(),
		tile_height_overrides,
		true,
		tile_column_metadata_overrides
	)
	result["tick"] = tick
	return result

static func _resolve_target_wall_profile(target_wall_profile) -> Dictionary:
	var profile: Dictionary = {
		"wall_height_levels": _WALL_HEIGHT_LEVELS,
		"column_extra_levels": _WALL_COLUMN_EXTRA_LEVELS,
		"column_span_interval": _WALL_COLUMN_SPAN_INTERVAL,
		"material_profile_key": _WALL_COLUMN_MATERIAL_PROFILE_KEY,
		"destructible_tag": _WALL_COLUMN_DESTRUCTIBLE_TAG,
		"brittleness": _WALL_COLUMN_BRITTLENESS,
		"pillar_height_scale": _WALL_PILLAR_HEIGHT_SCALE,
		"pillar_density_scale": _WALL_PILLAR_DENSITY_SCALE,
	}
	if target_wall_profile == null:
		return profile
	var values: Dictionary = {}
	if target_wall_profile.has_method("to_dict"):
		var values_variant = target_wall_profile.call("to_dict")
		if values_variant is Dictionary:
			values = (values_variant as Dictionary).duplicate(true)
	else:
		values = {
			"wall_height_levels": target_wall_profile.get("wall_height_levels", profile.get("wall_height_levels", _WALL_HEIGHT_LEVELS)),
			"column_extra_levels": target_wall_profile.get("column_extra_levels", profile.get("column_extra_levels", _WALL_COLUMN_EXTRA_LEVELS)),
			"column_span_interval": target_wall_profile.get("column_span_interval", profile.get("column_span_interval", _WALL_COLUMN_SPAN_INTERVAL)),
			"material_profile_key": target_wall_profile.get("material_profile_key", profile.get("material_profile_key", _WALL_COLUMN_MATERIAL_PROFILE_KEY)),
			"destructible_tag": target_wall_profile.get("destructible_tag", profile.get("destructible_tag", _WALL_COLUMN_DESTRUCTIBLE_TAG)),
			"brittleness": target_wall_profile.get("brittleness", profile.get("brittleness", _WALL_COLUMN_BRITTLENESS)),
			"pillar_height_scale": target_wall_profile.get("pillar_height_scale", profile.get("pillar_height_scale", _WALL_PILLAR_HEIGHT_SCALE)),
			"pillar_density_scale": target_wall_profile.get("pillar_density_scale", profile.get("pillar_density_scale", _WALL_PILLAR_DENSITY_SCALE)),
		}
	profile["wall_height_levels"] = maxi(1, int(values.get("wall_height_levels", profile.get("wall_height_levels", _WALL_HEIGHT_LEVELS))))
	profile["column_extra_levels"] = maxi(0, int(values.get("column_extra_levels", profile.get("column_extra_levels", _WALL_COLUMN_EXTRA_LEVELS))))
	profile["column_span_interval"] = maxi(1, int(values.get("column_span_interval", profile.get("column_span_interval", _WALL_COLUMN_SPAN_INTERVAL))))
	var material_profile_key := String(values.get("material_profile_key", profile.get("material_profile_key", _WALL_COLUMN_MATERIAL_PROFILE_KEY))).strip_edges()
	var destructible_tag := String(values.get("destructible_tag", profile.get("destructible_tag", _WALL_COLUMN_DESTRUCTIBLE_TAG))).strip_edges()
	profile["material_profile_key"] = _WALL_COLUMN_MATERIAL_PROFILE_KEY if material_profile_key == "" else material_profile_key
	profile["destructible_tag"] = _WALL_COLUMN_DESTRUCTIBLE_TAG if destructible_tag == "" else destructible_tag
	profile["brittleness"] = clampf(float(values.get("brittleness", profile.get("brittleness", _WALL_COLUMN_BRITTLENESS))), 0.1, 3.0)
	profile["pillar_height_scale"] = clampf(float(values.get("pillar_height_scale", profile.get("pillar_height_scale", _WALL_PILLAR_HEIGHT_SCALE))), 0.25, 3.0)
	profile["pillar_density_scale"] = clampf(float(values.get("pillar_density_scale", profile.get("pillar_density_scale", _WALL_PILLAR_DENSITY_SCALE))), 0.25, 3.0)
	return profile

static func apply_native_voxel_stage_delta(controller, tick: int, payload: Dictionary) -> Dictionary:
	if controller == null:
		return _stage_result({
			"ok": false,
			"changed": false,
			"error": "invalid_controller",
			"tick": tick,
			"changed_tiles": [],
			"changed_chunks": [],
		}, _PATH_INVALID_CONTROLLER, false)
	var native_ops = _extract_native_op_payloads(payload)
	var direct_impact_ops := _build_direct_impact_voxel_ops(controller, payload)
	var changed_chunk_rows = _extract_changed_chunks(payload)
	var changed_chunks = _normalize_chunk_keys(changed_chunk_rows)
	var failure_paths: Array = []
	if native_ops.is_empty() and not direct_impact_ops.is_empty():
		native_ops = direct_impact_ops.duplicate(true)
	if native_ops.is_empty():
		var contact_fallback_result := _apply_contact_confirmed_direct_fallback(controller, tick, payload, _PATH_CONTACT_FALLBACK_PRE_OPS)
		if bool(contact_fallback_result.get("changed", false)):
			return contact_fallback_result
		failure_paths.append(String(contact_fallback_result.get("mutation_path", _PATH_CONTACT_FALLBACK_PRE_OPS)))
		var env_snapshot = controller._environment_snapshot.duplicate(true)
		var changed_region = _extract_changed_region(payload)
		var changed_tiles = _tiles_from_changed_chunks_or_region(env_snapshot, payload, changed_chunk_rows, changed_region)
		if not changed_tiles.is_empty():
			var lowered_levels: Dictionary = {}
			for tile_variant in changed_tiles:
				var tile_id := String(tile_variant).strip_edges()
				if tile_id == "":
					continue
				lowered_levels[tile_id] = 1
			if not lowered_levels.is_empty():
				var fallback_result = _apply_column_surface_delta(
					controller,
					env_snapshot,
					lowered_levels.keys(),
					lowered_levels,
					false
				)
				fallback_result = _stage_result(fallback_result, _PATH_CHANGED_REGION_FALLBACK)
				fallback_result["tick"] = tick
				if bool(fallback_result.get("changed", false)):
					return fallback_result
		failure_paths.append(_PATH_CHANGED_REGION_FALLBACK)
		var missing_result := {
			"ok": false,
			"changed": false,
			"error": "native_voxel_op_payload_missing",
			"details": "native voxel op payload required; CPU surface-delta fallback disabled",
			"tick": tick,
			"changed_tiles": [],
			"changed_chunks": changed_chunks,
		}
		missing_result["failure_paths"] = failure_paths.duplicate(true)
		return _stage_result(missing_result, _PATH_NO_OP_PAYLOAD, false)
	var ops_result = apply_native_voxel_ops_payload(controller, tick, {"op_payloads": native_ops, "changed_chunks": changed_chunk_rows})
	ops_result = _stage_result(ops_result, _PATH_NATIVE_OPS_PRIMARY)
	if bool(ops_result.get("changed", false)):
		return ops_result
	failure_paths.append(_PATH_NATIVE_OPS_PRIMARY)
	if not direct_impact_ops.is_empty() and not _native_op_arrays_equal(native_ops, direct_impact_ops):
		var direct_fallback_result := apply_native_voxel_ops_payload(controller, tick, {"op_payloads": direct_impact_ops, "changed_chunks": changed_chunk_rows})
		direct_fallback_result = _stage_result(direct_fallback_result, _PATH_DIRECT_IMPACT_OP_FALLBACK)
		if bool(direct_fallback_result.get("changed", false)):
			return direct_fallback_result
		failure_paths.append(_PATH_DIRECT_IMPACT_OP_FALLBACK)
	var post_ops_contact_fallback_result := _apply_contact_confirmed_direct_fallback(controller, tick, payload, _PATH_CONTACT_FALLBACK_POST_OPS)
	if bool(post_ops_contact_fallback_result.get("changed", false)):
		return post_ops_contact_fallback_result
	failure_paths.append(String(post_ops_contact_fallback_result.get("mutation_path", _PATH_CONTACT_FALLBACK_POST_OPS)))
	ops_result["ok"] = false
	ops_result["changed"] = false
	ops_result["error"] = "native_voxel_stage_no_mutation"
	ops_result["details"] = "native voxel stage produced no direct op mutations; CPU surface-delta fallback disabled"
	ops_result["tick"] = tick
	ops_result["changed_tiles"] = []
	ops_result["changed_chunks"] = changed_chunks
	ops_result["failure_paths"] = failure_paths.duplicate(true)
	return _stage_result(ops_result, _PATH_STAGE_NO_MUTATION, false)

static func _build_direct_impact_voxel_ops(controller, payload: Dictionary) -> Array:
	var env_snapshot: Dictionary = controller._environment_snapshot.duplicate(true)
	var width := int(env_snapshot.get("width", 0))
	var height := int(env_snapshot.get("height", 0))
	if width <= 0 or height <= 0:
		return []
	var contacts := _extract_projectile_contact_rows(payload)
	if contacts.is_empty():
		return []
	var changed_chunks = _extract_changed_chunks(payload)
	var changed_region = _extract_changed_region(payload)
	var ops: Array = []
	var seq := 0
	for row_variant in contacts:
		if not (row_variant is Dictionary):
			continue
		var row = row_variant as Dictionary
		var point := _extract_contact_point(row)
		var target := _resolve_existing_contact_tile(env_snapshot, payload, point, changed_chunks, changed_region)
		if target.is_empty():
			continue
		var x := clampi(int(target.get("x", 0)), 0, width - 1)
		var z := clampi(int(target.get("z", 0)), 0, height - 1)
		var impulse := maxf(0.0, float(row.get("contact_impulse", row.get("impulse", 0.0))))
		var speed := maxf(0.0, float(row.get("relative_speed", row.get("contact_velocity", 0.0))))
		var value := clampf((impulse * 0.02) + (speed * 0.01), 0.35, 2.0)
		var radius := clampf(float(row.get("projectile_radius", 0.0)), 0.0, 1.6)
		if radius <= 0.0:
			radius = clampf(0.35 + minf(1.25, value * 0.4), 0.35, 1.6)
		ops.append({
			"sequence_id": seq,
			"x": x,
			"y": maxi(0, int(round(point.y))),
			"z": z,
			"operation": "fracture",
			"value": value,
			"radius": radius,
			"source": "projectile_direct_impact",
			"projectile_id": int(row.get("body_id", 0)),
		})
		seq += 1
	return ops

static func _apply_contact_confirmed_direct_fallback(controller, tick: int, payload: Dictionary, path_tag: String = _PATH_CONTACT_FALLBACK_PRE_OPS) -> Dictionary:
	var env_snapshot: Dictionary = controller._environment_snapshot.duplicate(true)
	var contacts := _extract_projectile_contact_rows(payload)
	if contacts.is_empty() or env_snapshot.is_empty():
		return _stage_result({"ok": false, "changed": false, "error": "contact_fallback_unavailable", "tick": tick, "changed_tiles": [], "changed_chunks": []}, path_tag, false)
	var changed_chunks = _extract_changed_chunks(payload)
	var changed_region = _extract_changed_region(payload)
	var lowered_levels: Dictionary = {}
	for row_variant in contacts:
		if not (row_variant is Dictionary):
			continue
		var row = row_variant as Dictionary
		var point := _extract_contact_point(row)
		var target := _resolve_existing_contact_tile(env_snapshot, payload, point, changed_chunks, changed_region)
		if target.is_empty():
			continue
		var tile_id := TileKeyUtilsScript.tile_id(int(target.get("x", 0)), int(target.get("z", 0)))
		var impulse := maxf(0.0, float(row.get("contact_impulse", row.get("impulse", 0.0))))
		var speed := maxf(0.0, float(row.get("relative_speed", row.get("contact_velocity", 0.0))))
		var value := clampf((impulse * 0.02) + (speed * 0.01), 0.35, 2.0)
		var levels := clampi(int(round(value * _NATIVE_OP_VALUE_TO_LEVELS)), 1, _NATIVE_OP_MAX_LEVELS)
		lowered_levels[tile_id] = maxi(int(lowered_levels.get(tile_id, 0)), levels)
	if lowered_levels.is_empty():
		var changed_tiles = _mutable_changed_tiles(env_snapshot, payload, changed_chunks, changed_region)
		for tile_variant in changed_tiles:
			var tile_id := String(tile_variant).strip_edges()
			if tile_id != "":
				lowered_levels[tile_id] = 1
	if lowered_levels.is_empty():
		return _stage_result({"ok": false, "changed": false, "error": "contact_fallback_targets_missing", "tick": tick, "changed_tiles": [], "changed_chunks": []}, path_tag, false)
	var fallback_result = _apply_column_surface_delta(
		controller,
		env_snapshot,
		lowered_levels.keys(),
		lowered_levels,
		false
	)
	fallback_result["tick"] = tick
	return _stage_result(fallback_result, path_tag)

static func _extract_projectile_contact_rows(payload: Dictionary) -> Array:
	var out: Array = []
	_collect_projectile_contact_rows(payload, out, 0)
	return out

static func _collect_projectile_contact_rows(source: Dictionary, out: Array, depth: int) -> void:
	if depth > 3:
		return
	for key in ["physics_contacts", "physics_server_contacts", "contacts"]:
		var rows_variant = source.get(key, [])
		if not (rows_variant is Array):
			continue
		for row_variant in (rows_variant as Array):
			if row_variant is Dictionary:
				var row = row_variant as Dictionary
				if int(row.get("body_id", 0)) > 0 and String(row.get("projectile_kind", "")).to_lower() == "voxel_chunk":
					out.append(row.duplicate(true))
	for key in ["voxel_failure_emission", "result_fields", "result", "payload", "execution", "voxel_result", "source"]:
		var nested_variant = source.get(key, {})
		if nested_variant is Dictionary:
			_collect_projectile_contact_rows(nested_variant as Dictionary, out, depth + 1)

static func _extract_contact_point(row: Dictionary) -> Vector3:
	var point_variant = row.get("contact_point", row.get("position", Vector3.ZERO))
	if point_variant is Vector3:
		return point_variant as Vector3
	if point_variant is Dictionary:
		var point_dict = point_variant as Dictionary
		return Vector3(float(point_dict.get("x", 0.0)), float(point_dict.get("y", 0.0)), float(point_dict.get("z", 0.0)))
	return Vector3.ZERO

static func _native_op_arrays_equal(a: Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	for i in range(a.size()):
		var left_variant = a[i]
		var right_variant = b[i]
		if not (left_variant is Dictionary and right_variant is Dictionary):
			return false
		var left = left_variant as Dictionary
		var right = right_variant as Dictionary
		if _native_op_less(left, right) or _native_op_less(right, left):
			return false
	return true

static func apply_native_voxel_ops_payload(controller, tick: int, payload: Dictionary) -> Dictionary:
	if controller == null:
		return {"ok": false, "changed": false, "error": "invalid_controller", "tick": tick, "changed_tiles": [], "changed_chunks": []}
	var changed_chunk_rows = _resolve_changed_chunks_from_payload(payload)
	var extracted_changed_chunks = _normalize_chunk_keys(changed_chunk_rows)
	var ops = _resolve_native_ops_from_payload(payload)
	if ops.is_empty():
		return {
			"ok": false,
			"changed": false,
			"error": "native_voxel_op_payload_missing",
			"details": "native voxel op payload required; CPU fallback disabled",
			"tick": tick,
			"changed_tiles": [],
			"changed_chunks": extracted_changed_chunks,
		}
	var env_snapshot = controller._environment_snapshot.duplicate(true)
	if env_snapshot.is_empty():
		return {
			"ok": false,
			"changed": false,
			"error": "environment_snapshot_unavailable",
			"details": "environment snapshot unavailable for native voxel op mutation",
			"tick": tick,
			"changed_tiles": [],
			"changed_chunks": extracted_changed_chunks,
		}
	var width := int(env_snapshot.get("width", 0))
	var height := int(env_snapshot.get("height", 0))
	if width <= 0 or height <= 0:
		return {
			"ok": false,
			"changed": false,
			"error": "environment_dimensions_invalid",
			"details": "environment dimensions invalid for native voxel op mutation",
			"tick": tick,
			"changed_tiles": [],
			"changed_chunks": extracted_changed_chunks,
		}
	ops.sort_custom(func(a, b): return _native_op_less(a as Dictionary, b as Dictionary))
	var signed_levels: Dictionary = {}
	for op_variant in ops:
		if not (op_variant is Dictionary):
			continue
		var op = op_variant as Dictionary
		var x := clampi(int(op.get("x", 0)), 0, width - 1)
		var z := clampi(int(op.get("z", 0)), 0, height - 1)
		var op_name := String(op.get("operation", "fracture")).to_lower()
		var value := maxf(0.05, float(op.get("value", 1.0)))
		var levels := clampi(int(round(value * _NATIVE_OP_VALUE_TO_LEVELS)), 1, _NATIVE_OP_MAX_LEVELS)
		var radius := maxf(0.0, float(op.get("radius", 0.0)))
		var raise_surface := op_name in ["add", "max"] or (op_name == "set" and value >= 1.0)
		var sign := 1 if raise_surface else -1
		var radius_cells := maxi(0, int(ceil(radius)))
		for dz in range(-radius_cells, radius_cells + 1):
			for dx in range(-radius_cells, radius_cells + 1):
				if radius_cells > 0 and float(dx * dx + dz * dz) > radius * radius:
					continue
				var tx := clampi(x + dx, 0, width - 1)
				var tz := clampi(z + dz, 0, height - 1)
				var tile_id = TileKeyUtilsScript.tile_id(tx, tz)
				signed_levels[tile_id] = int(signed_levels.get(tile_id, 0)) + sign * levels
	if signed_levels.is_empty():
		return {
			"ok": false,
			"changed": false,
			"error": "native_voxel_ops_empty_after_normalization",
			"details": "native voxel ops resolved to no valid signed surface deltas",
			"tick": tick,
			"changed_tiles": [],
			"changed_chunks": extracted_changed_chunks,
		}
	var lower_overrides: Dictionary = {}
	var raise_overrides: Dictionary = {}
	for tile_id_variant in signed_levels.keys():
		var tile_id := String(tile_id_variant)
		var signed = int(signed_levels.get(tile_id, 0))
		if signed < 0:
			lower_overrides[tile_id] = abs(signed)
		elif signed > 0:
			raise_overrides[tile_id] = signed
	var merged_tiles_map: Dictionary = {}
	var last_result: Dictionary = {"ok": true, "changed": false, "error": "", "changed_tiles": [], "changed_chunks": []}
	if not lower_overrides.is_empty():
		last_result = _apply_column_surface_delta(controller, env_snapshot, lower_overrides.keys(), lower_overrides, false, {}, false)
		env_snapshot = controller._environment_snapshot
		for tile_variant in last_result.get("changed_tiles", []):
			merged_tiles_map[String(tile_variant)] = true
	if not raise_overrides.is_empty():
		last_result = _apply_column_surface_delta(controller, env_snapshot, raise_overrides.keys(), raise_overrides, true, {}, false)
		for tile_variant in last_result.get("changed_tiles", []):
			merged_tiles_map[String(tile_variant)] = true
	var merged_tiles: Array = merged_tiles_map.keys()
	merged_tiles.sort_custom(func(a, b): return String(a) < String(b))
	var changed_chunks = _chunk_keys_for_tiles(controller._environment_snapshot, merged_tiles)
	last_result["tick"] = tick
	last_result["changed"] = not merged_tiles.is_empty()
	last_result["changed_tiles"] = merged_tiles
	last_result["changed_chunks"] = changed_chunks
	if bool(last_result.get("changed", false)):
		last_result["environment_snapshot"] = controller._environment_snapshot.duplicate(true)
		last_result["network_state_snapshot"] = controller._network_state_snapshot.duplicate(true)
	return last_result

static func _apply_column_surface_delta(
	controller,
	env_snapshot: Dictionary,
	changed_tiles: Array,
	height_overrides: Dictionary,
	raise_surface: bool,
	column_metadata_overrides: Dictionary = {},
	include_snapshots: bool = true
) -> Dictionary:
	var voxel_world: Dictionary = env_snapshot.get("voxel_world", {})
	var columns: Array = voxel_world.get("columns", [])
	if columns.is_empty():
		return {"ok": true, "changed": false, "error": ""}
	var sea_level = int(voxel_world.get("sea_level", 1))
	var world_height = int(voxel_world.get("height", 36))
	var chunk_size = maxi(4, int(voxel_world.get("block_rows_chunk_size", 12)))
	var column_by_tile: Dictionary = voxel_world.get("column_index_by_tile", {})
	if column_by_tile.is_empty():
		for i in range(columns.size()):
			var column_variant = columns[i]
			if not (column_variant is Dictionary):
				continue
			var column = column_variant as Dictionary
			column_by_tile[TileKeyUtilsScript.tile_id(int(column.get("x", 0)), int(column.get("z", 0)))] = i
	var tile_index: Dictionary = env_snapshot.get("tile_index", {})
	var touched_chunks: Dictionary = {}
	var changed_tiles_sorted: Array = []
	for tile_variant in changed_tiles:
		var tile_id = String(tile_variant).strip_edges()
		if tile_id == "" or not column_by_tile.has(tile_id):
			continue
		var column_index = int(column_by_tile.get(tile_id, -1))
		if column_index < 0 or column_index >= columns.size():
			continue
		var column_variant = columns[column_index]
		if not (column_variant is Dictionary):
			continue
		var column = column_variant as Dictionary
		var x := int(column.get("x", 0))
		var z := int(column.get("z", 0))
		var current_surface := int(column.get("surface_y", sea_level))
		var delta_levels := maxi(1, int(height_overrides.get(tile_id, 1)))
		var next_surface := current_surface
		if raise_surface:
			next_surface = clampi(current_surface + delta_levels, 1, world_height - 2)
		else:
			next_surface = clampi(current_surface - delta_levels, 0, world_height - 2)
		var metadata_changed := false
		var metadata_variant = column_metadata_overrides.get(tile_id, {})
		if metadata_variant is Dictionary:
			var metadata = metadata_variant as Dictionary
			for key_variant in metadata.keys():
				var key := String(key_variant)
				var value = metadata.get(key_variant)
				if column.get(key) == value:
					continue
				column[key] = value
				metadata_changed = true
		if next_surface == current_surface and not metadata_changed:
			continue
		column["surface_y"] = next_surface
		if raise_surface and next_surface != current_surface:
			var material_profile_key := String(column.get("material_profile_key", _WALL_COLUMN_MATERIAL_PROFILE_KEY))
			var brittleness := clampf(float(column.get("brittleness", _WALL_COLUMN_BRITTLENESS)), 0.1, 3.0)
			var block_profile := _wall_material_blocks(material_profile_key, brittleness)
			column["top_block"] = String(block_profile.get("top_block", "gravel"))
			column["subsoil_block"] = String(block_profile.get("subsoil_block", "dirt"))
			var structural_strength_scale := _strength_scale_for_brittleness(brittleness)
			column["structural_strength_scale"] = structural_strength_scale
			column["fracture_threshold_scale"] = structural_strength_scale
		columns[column_index] = column
		touched_chunks["%d:%d" % [int(floor(float(x) / float(chunk_size))), int(floor(float(z) / float(chunk_size)))]] = true
		changed_tiles_sorted.append(tile_id)
		if tile_index.has(tile_id):
			var tile_variant_row = tile_index.get(tile_id, {})
			if tile_variant_row is Dictionary:
				var tile_row = tile_variant_row as Dictionary
				tile_row["elevation"] = clampf(float(next_surface) / float(maxi(1, world_height - 1)), 0.0, 1.0)
				tile_index[tile_id] = tile_row
	if changed_tiles_sorted.is_empty():
		return {"ok": true, "changed": false, "error": "", "changed_tiles": [], "changed_chunks": []}
	changed_tiles_sorted.sort_custom(func(a, b): return String(a) < String(b))
	var touched_chunks_sorted: Array = touched_chunks.keys()
	touched_chunks_sorted.sort_custom(func(a, b): return String(a) < String(b))
	var chunk_rows_by_chunk: Dictionary = voxel_world.get("block_rows_by_chunk", {})
	if chunk_rows_by_chunk.is_empty():
		for column_variant in columns:
			if not (column_variant is Dictionary):
				continue
			var column = column_variant as Dictionary
			var cx := int(floor(float(int(column.get("x", 0))) / float(chunk_size)))
			var cz := int(floor(float(int(column.get("z", 0))) / float(chunk_size)))
			touched_chunks["%d:%d" % [cx, cz]] = true
	_rebuild_chunk_rows_from_columns(columns, chunk_rows_by_chunk, chunk_size, sea_level, touched_chunks.keys())
	var block_rows: Array = []
	var block_counts: Dictionary = {}
	var chunk_keys = chunk_rows_by_chunk.keys()
	chunk_keys.sort_custom(func(a, b): return String(a) < String(b))
	for key_variant in chunk_keys:
		var rows_variant = chunk_rows_by_chunk.get(key_variant, [])
		if not (rows_variant is Array):
			continue
		var rows = rows_variant as Array
		block_rows.append_array(rows)
		for row_variant in rows:
			if not (row_variant is Dictionary):
				continue
			var row = row_variant as Dictionary
			var block_type = String(row.get("type", "air"))
			block_counts[block_type] = int(block_counts.get(block_type, 0)) + 1
	voxel_world["columns"] = columns
	voxel_world["column_index_by_tile"] = column_by_tile
	voxel_world["block_rows_by_chunk"] = chunk_rows_by_chunk
	voxel_world["block_rows_chunk_size"] = chunk_size
	voxel_world["block_rows"] = block_rows
	voxel_world["block_type_counts"] = block_counts
	voxel_world["surface_y_buffer"] = _pack_surface_y_buffer(columns, int(env_snapshot.get("width", 0)), int(env_snapshot.get("height", 0)))
	env_snapshot["voxel_world"] = voxel_world
	env_snapshot["tile_index"] = tile_index
	var tiles: Array = env_snapshot.get("tiles", [])
	if not tiles.is_empty():
		for i in range(tiles.size()):
			var tile_variant = tiles[i]
			if not (tile_variant is Dictionary):
				continue
			var tile_row = tile_variant as Dictionary
			var tile_id = String(tile_row.get("tile_id", ""))
			if tile_id == "" or not tile_index.has(tile_id):
				continue
			tiles[i] = (tile_index[tile_id] as Dictionary).duplicate(true)
		env_snapshot["tiles"] = tiles
	controller._environment_snapshot = env_snapshot
	controller._transform_changed_last_tick = true
	controller._transform_changed_tiles_last_tick = changed_tiles_sorted.duplicate(true)
	var result: Dictionary = {
		"ok": true,
		"changed": true,
		"error": "",
		"changed_tiles": changed_tiles_sorted,
		"changed_chunks": touched_chunks_sorted,
	}
	if include_snapshots:
		result["environment_snapshot"] = env_snapshot.duplicate(true)
		result["network_state_snapshot"] = controller._network_state_snapshot.duplicate(true)
	return result

static func _strength_scale_for_brittleness(brittleness: float) -> float:
	return clampf(1.15 - (clampf(brittleness, 0.1, 3.0) * 0.35), 0.15, 1.15)

static func _wall_material_blocks(material_profile_key: String, brittleness: float) -> Dictionary:
	var material_key := material_profile_key.strip_edges().to_lower()
	var brittle := clampf(brittleness, 0.1, 3.0)
	if material_key.find("sand") != -1:
		return {"top_block": "sand", "subsoil_block": "sand"}
	if material_key.find("clay") != -1:
		return {"top_block": "clay", "subsoil_block": "clay" if brittle <= 1.4 else "sand"}
	if material_key.find("gravel") != -1:
		return {"top_block": "gravel", "subsoil_block": "gravel"}
	if brittle >= 2.0:
		return {"top_block": "sand", "subsoil_block": "gravel"}
	if brittle >= 1.2:
		return {"top_block": "gravel", "subsoil_block": "dirt"}
	if brittle <= 0.6:
		return {"top_block": "clay", "subsoil_block": "dirt"}
	return {"top_block": "dirt", "subsoil_block": "gravel"}

static func _rebuild_chunk_rows_from_columns(
	columns: Array,
	chunk_rows_by_chunk: Dictionary,
	chunk_size: int,
	sea_level: int,
	target_chunk_keys: Array
) -> void:
	var target: Dictionary = {}
	for key_variant in target_chunk_keys:
		var key = String(key_variant).strip_edges()
		if key == "":
			continue
		target[key] = true
	for key_variant in target.keys():
		var key = String(key_variant)
		var parts = key.split(":")
		if parts.size() != 2:
			continue
		var cx = int(parts[0])
		var cz = int(parts[1])
		var rows: Array = []
		for column_variant in columns:
			if not (column_variant is Dictionary):
				continue
			var column = column_variant as Dictionary
			var x = int(column.get("x", 0))
			var z = int(column.get("z", 0))
			if int(floor(float(x) / float(chunk_size))) != cx or int(floor(float(z) / float(chunk_size))) != cz:
				continue
			var surface_y = int(column.get("surface_y", sea_level))
			var top_block = String(column.get("top_block", "stone"))
			var subsoil = String(column.get("subsoil_block", "stone"))
			for y in range(surface_y + 1):
				var block_type = "stone"
				if y == surface_y:
					block_type = top_block
				elif y >= surface_y - 2:
					block_type = subsoil
				rows.append({"x": x, "y": y, "z": z, "type": block_type})
			if surface_y < sea_level:
				for wy in range(surface_y + 1, sea_level + 1):
					rows.append({"x": x, "y": wy, "z": z, "type": "water"})
		chunk_rows_by_chunk[key] = rows

static func _pack_surface_y_buffer(columns: Array, width: int, height: int) -> PackedInt32Array:
	var packed := PackedInt32Array()
	if width <= 0 or height <= 0:
		return packed
	packed.resize(width * height)
	for column_variant in columns:
		if not (column_variant is Dictionary):
			continue
		var column = column_variant as Dictionary
		var x = int(column.get("x", 0))
		var z = int(column.get("z", 0))
		if x < 0 or x >= width or z < 0 or z >= height:
			continue
		packed[z * width + x] = int(column.get("surface_y", 0))
	return packed

static func _extract_native_op_payloads(payload: Dictionary) -> Array:
	var out: Array = []
	_collect_native_op_payloads(payload, out, 0)
	return out

static func _collect_native_op_payloads(source: Dictionary, out: Array, depth: int) -> void:
	if depth > 3:
		return
	for key in ["op_payloads", "operations", "voxel_ops"]:
		var rows_variant = source.get(key, [])
		if not (rows_variant is Array):
			continue
		for row_variant in (rows_variant as Array):
			if row_variant is Dictionary:
				out.append((row_variant as Dictionary).duplicate(true))
	for key in ["voxel_failure_emission", "result_fields", "result", "payload", "execution", "voxel_result", "source"]:
		var nested_variant = source.get(key, {})
		if nested_variant is Dictionary:
			_collect_native_op_payloads(nested_variant as Dictionary, out, depth + 1)

static func _extract_changed_chunks(payload: Dictionary) -> Array:
	var out: Array = []
	_collect_changed_chunks(payload, out, 0)
	return out

static func _collect_changed_chunks(source: Dictionary, out: Array, depth: int) -> void:
	if depth > 3:
		return
	var chunks_variant = source.get("changed_chunks", [])
	if chunks_variant is Array:
		for chunk_variant in (chunks_variant as Array):
			if chunk_variant is Dictionary:
				out.append((chunk_variant as Dictionary).duplicate(true))
	for key in ["voxel_failure_emission", "result_fields", "result", "payload", "execution", "voxel_result", "source"]:
		var nested_variant = source.get(key, {})
		if nested_variant is Dictionary:
			_collect_changed_chunks(nested_variant as Dictionary, out, depth + 1)

static func _tiles_from_changed_chunks_or_region(
	env_snapshot: Dictionary,
	payload: Dictionary,
	changed_chunks: Array = [],
	changed_region: Dictionary = {}
) -> Array:
	var voxel_world: Dictionary = env_snapshot.get("voxel_world", {})
	var columns: Array = voxel_world.get("columns", [])
	if columns.is_empty():
		return []
	var column_by_tile := _column_index_by_tile(voxel_world, columns)
	if column_by_tile.is_empty():
		return []
	var chunk_size = maxi(4, int(voxel_world.get("block_rows_chunk_size", 12)))
	var tiles_map: Dictionary = {}
	var effective_chunks: Array = changed_chunks
	if effective_chunks.is_empty():
		effective_chunks = _extract_changed_chunks(payload)
	for chunk_variant in effective_chunks:
		if not (chunk_variant is Dictionary):
			continue
		var chunk = chunk_variant as Dictionary
		var cx = int(chunk.get("x", 0))
		var cz = int(chunk.get("z", chunk.get("y", 0)))
		for column_variant in columns:
			if not (column_variant is Dictionary):
				continue
			var column = column_variant as Dictionary
			var x := int(column.get("x", 0))
			var z := int(column.get("z", 0))
			if int(floor(float(x) / float(chunk_size))) == cx and int(floor(float(z) / float(chunk_size))) == cz:
				var tile_id := TileKeyUtilsScript.tile_id(x, z)
				if column_by_tile.has(tile_id):
					tiles_map[tile_id] = true
	var region := changed_region
	if region.is_empty():
		region = _extract_changed_region(payload)
	if not region.is_empty():
		var min_row = region.get("min", {})
		var max_row = region.get("max", {})
		if min_row is Dictionary and max_row is Dictionary:
			var width := int(env_snapshot.get("width", int(voxel_world.get("width", 0))))
			var height := int(env_snapshot.get("height", int(voxel_world.get("depth", 0))))
			var min_x = int((min_row as Dictionary).get("x", 0))
			var min_z = int((min_row as Dictionary).get("z", 0))
			var max_x = int((max_row as Dictionary).get("x", min_x))
			var max_z = int((max_row as Dictionary).get("z", min_z))
			if width > 0 and height > 0:
				min_x = clampi(min_x, 0, width - 1)
				max_x = clampi(max_x, 0, width - 1)
				min_z = clampi(min_z, 0, height - 1)
				max_z = clampi(max_z, 0, height - 1)
			for z in range(mini(min_z, max_z), maxi(min_z, max_z) + 1):
				for x in range(mini(min_x, max_x), maxi(min_x, max_x) + 1):
					var tile_id := TileKeyUtilsScript.tile_id(x, z)
					if column_by_tile.has(tile_id):
						tiles_map[tile_id] = true
	var tiles: Array = tiles_map.keys()
	tiles.sort_custom(func(a, b): return String(a) < String(b))
	return tiles

static func _mutable_changed_tiles(
	env_snapshot: Dictionary,
	payload: Dictionary,
	changed_chunks: Array = [],
	changed_region: Dictionary = {}
) -> Array:
	var candidate_tiles := _tiles_from_changed_chunks_or_region(env_snapshot, payload, changed_chunks, changed_region)
	if candidate_tiles.is_empty():
		return []
	var voxel_world: Dictionary = env_snapshot.get("voxel_world", {})
	var columns: Array = voxel_world.get("columns", [])
	if columns.is_empty():
		return []
	var column_by_tile := _column_index_by_tile(voxel_world, columns)
	if column_by_tile.is_empty():
		return []
	var mutable_tiles: Array = []
	for tile_variant in candidate_tiles:
		var tile_id := String(tile_variant).strip_edges()
		if tile_id == "" or not column_by_tile.has(tile_id):
			continue
		var column_index := int(column_by_tile.get(tile_id, -1))
		if column_index < 0 or column_index >= columns.size():
			continue
		var column_variant = columns[column_index]
		if not (column_variant is Dictionary):
			continue
		if int((column_variant as Dictionary).get("surface_y", 0)) <= 0:
			continue
		mutable_tiles.append(tile_id)
	return mutable_tiles

static func _resolve_existing_contact_tile(
	env_snapshot: Dictionary,
	payload: Dictionary,
	contact_point: Vector3,
	changed_chunks: Array = [],
	changed_region: Dictionary = {}
) -> Dictionary:
	var preferred_tiles := _mutable_changed_tiles(env_snapshot, payload, changed_chunks, changed_region)
	return ContactTileResolverScript.resolve_existing_contact_tile(env_snapshot, contact_point, preferred_tiles)

static func _stage_result(result: Dictionary, path_tag: String, changed_default: bool = false) -> Dictionary:
	var out := result.duplicate(true)
	var resolved_path := path_tag.strip_edges()
	if resolved_path == "":
		resolved_path = _PATH_STAGE_NO_MUTATION
	out["mutation_path"] = resolved_path
	out["mutation_path_state"] = "success" if bool(out.get("changed", changed_default)) else "failure"
	return out

static func _column_index_by_tile(voxel_world: Dictionary, columns: Array) -> Dictionary:
	var column_by_tile: Dictionary = voxel_world.get("column_index_by_tile", {})
	if column_by_tile.is_empty():
		for i in range(columns.size()):
			var column_variant = columns[i]
			if not (column_variant is Dictionary):
				continue
			var column = column_variant as Dictionary
			column_by_tile[TileKeyUtilsScript.tile_id(int(column.get("x", 0)), int(column.get("z", 0)))] = i
	return column_by_tile

static func _extract_changed_region(payload: Dictionary) -> Dictionary:
	return _find_changed_region(payload, 0)

static func _find_changed_region(source: Dictionary, depth: int) -> Dictionary:
	if depth > 3:
		return {}
	var region_variant = source.get("changed_region", {})
	if region_variant is Dictionary:
		var region = region_variant as Dictionary
		if bool(region.get("valid", false)):
			return region
	for key in ["voxel_failure_emission", "result_fields", "result", "payload", "execution", "voxel_result", "source"]:
		var nested_variant = source.get(key, {})
		if nested_variant is Dictionary:
			var nested = _find_changed_region(nested_variant as Dictionary, depth + 1)
			if not nested.is_empty():
				return nested
	return {}

static func _native_op_less(left: Dictionary, right: Dictionary) -> bool:
	var left_sequence := int(left.get("sequence_id", 0))
	var right_sequence := int(right.get("sequence_id", 0))
	if left_sequence != right_sequence:
		return left_sequence < right_sequence
	var left_x := int(left.get("x", 0))
	var right_x := int(right.get("x", 0))
	if left_x != right_x:
		return left_x < right_x
	var left_y := int(left.get("y", 0))
	var right_y := int(right.get("y", 0))
	if left_y != right_y:
		return left_y < right_y
	var left_z := int(left.get("z", 0))
	var right_z := int(right.get("z", 0))
	if left_z != right_z:
		return left_z < right_z
	return String(left.get("operation", "set")) < String(right.get("operation", "set"))

static func _resolve_native_ops_from_payload(payload: Dictionary) -> Array:
	var payload_rows = payload.get("op_payloads", null)
	if payload_rows is Array:
		var out: Array = []
		for row_variant in (payload_rows as Array):
			if row_variant is Dictionary:
				out.append((row_variant as Dictionary).duplicate(true))
		return out
	return _extract_native_op_payloads(payload)

static func _resolve_changed_chunks_from_payload(payload: Dictionary) -> Array:
	var payload_rows = payload.get("changed_chunks", null)
	if payload_rows is Array:
		var out: Array = []
		for row_variant in (payload_rows as Array):
			if row_variant is Dictionary:
				out.append((row_variant as Dictionary).duplicate(true))
			elif row_variant is String:
				var key := String(row_variant).strip_edges()
				if key != "":
					out.append(key)
		return out
	return _extract_changed_chunks(payload)

static func _chunk_keys_for_tiles(env_snapshot: Dictionary, changed_tiles: Array) -> Array:
	if changed_tiles.is_empty():
		return []
	var chunk_size := maxi(4, int(((env_snapshot.get("voxel_world", {}) as Dictionary).get("block_rows_chunk_size", 12))))
	var chunk_map: Dictionary = {}
	for tile_variant in changed_tiles:
		var tile_id := String(tile_variant)
		var parts = tile_id.split(":")
		if parts.size() != 2:
			continue
		var x = int(parts[0])
		var z = int(parts[1])
		chunk_map["%d:%d" % [int(floor(float(x) / float(chunk_size))), int(floor(float(z) / float(chunk_size)))]] = true
	var keys: Array = chunk_map.keys()
	keys.sort_custom(func(a, b): return String(a) < String(b))
	return keys

static func _normalize_chunk_keys(chunks: Array) -> Array:
	var keys_map: Dictionary = {}
	for chunk_variant in chunks:
		if chunk_variant is Dictionary:
			var chunk = chunk_variant as Dictionary
			keys_map["%d:%d" % [int(chunk.get("x", 0)), int(chunk.get("z", chunk.get("y", 0)))]] = true
		else:
			var key := String(chunk_variant).strip_edges()
			if key != "":
				keys_map[key] = true
	var keys: Array = keys_map.keys()
	keys.sort_custom(func(a, b): return String(a) < String(b))
	return keys
