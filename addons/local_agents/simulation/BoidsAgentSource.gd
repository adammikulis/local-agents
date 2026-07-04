extends Node3D
class_name LocalAgentsBoidsAgentSource

@export_category("Spawn lifecycle")
@export var source_enabled: bool = true
@export var use_spawn_lifecycle: bool = true
@export_range(0.0, 60.0, 0.05) var spawn_resolution_interval_seconds: float = 0.0
@export_range(1, 128, 1) var max_spawn_attempts: int = 24
@export_category("Spawn placement")
@export_range(1, 24, 1) var spawn_candidates_per_ring: int = 6
@export_range(0.0, 64.0, 0.01) var spawn_radius_min: float = 0.25
@export_range(0.01, 64.0, 0.01) var spawn_radius_step: float = 0.45
@export_range(0.0, 64.0, 0.01) var spawn_radius_max: float = 8.0
@export_range(0.0, 12.0, 0.01) var required_clearance: float = 0.75
@export var require_world_clearance_proxy: bool = true
@export_range(0.0, 12.0, 0.01) var max_terrain_step: float = 2.5
@export var align_spawn_to_world_clearance: bool = true

var _owner: Variant = null
var _environment_snapshot: Dictionary = {}
var _cycle_timer: float = 0.0
var _cached_positions: Dictionary = {}
var _cached_cycle: int = 0

func setup(owner: Variant) -> void:
	_owner = owner

func set_owner(owner: Variant) -> void:
	_owner = owner

func set_environment_snapshot(snapshot: Dictionary) -> void:
	_environment_snapshot = snapshot.duplicate(true) if snapshot is Dictionary else {}

func _ready() -> void:
	add_to_group("boids_agent_source")

func collect_boid_inputs(agents: Array, delta: float) -> Dictionary:
	var controls := _resolve_controls()
	if not controls["source_enabled"]:
		return {
			"ok": true,
			"backend": "boids_agent_source",
			"backend_authority": "boids_spawn_safe_pass_disabled",
			"enabled": false,
			"rows": [],
		}

	var needs_resolution := true
	if controls["use_spawn_lifecycle"]:
		_cycle_timer += maxf(0.0, float(delta))
		if controls["spawn_resolution_interval_seconds"] > 0.0 and _cycle_timer < controls["spawn_resolution_interval_seconds"]:
			needs_resolution = false
		else:
			_cycle_timer = 0.0
			_cached_cycle += 1

	var rows: Array = []
	var seen: Dictionary = {}
	var world := _resolve_world_snapshot(controls)
	for idx in range(agents.size()):
		var agent_variant = agents[idx]
		if not (agent_variant is Node):
			return _error_payload(
				"BOID_SOURCE_INVALID_INPUT",
				"collect_boid_inputs expected Node entries",
				"agent index %d is not a Node" % idx,
				{}
			)

		var agent := agent_variant as Node
		var agent_id := _resolve_agent_id(agent)
		if agent_id.is_empty():
			agent_id = "agent_%d" % agent.get_instance_id()

		var row_result := _collect_agent_row(agent, agent_id, needs_resolution, world, controls)
		if not bool(row_result.get("ok", false)):
			return {
				"ok": false,
				"backend": "boids_agent_source",
				"backend_authority": "boids_spawn_safe_contract",
				"error": String(row_result.get("error", "BOID_SOURCE_SPAWN_FAILED")),
				"error_code": String(row_result.get("error_code", "BOID_SOURCE_SPAWN_FAILED")),
				"error_detail": String(row_result.get("error_detail", "")),
				"scope_confirmation": "boid source safe-pass failed",
				"rows": [],
			}

		var row = row_result.get("row", {})
		if row is Dictionary and not row.is_empty():
			rows.append(row.duplicate(true))
			seen[agent_id] = true
		elif _cached_positions.has(agent_id):
			rows.append((_cached_positions[agent_id] as Dictionary).duplicate(true))
			seen[agent_id] = true

	for cached_id in _cached_positions.keys():
		if not bool(seen.get(cached_id, false)):
			_cached_positions.erase(cached_id)

	return {
		"ok": true,
		"backend": "boids_agent_source",
		"backend_authority": "boids_spawn_safe_pass",
		"rows": rows,
		"spawn_cycle": _cached_cycle,
		"rows_resolved": needs_resolution,
	}

func _collect_rows_without_safe_pass(agents: Array) -> Dictionary:
	var rows: Array = []
	for idx in range(agents.size()):
		var agent_variant = agents[idx]
		if not (agent_variant is Node):
			return _error_payload(
				"BOID_SOURCE_INVALID_INPUT",
				"collect_boid_inputs expected Node entries",
				"agent index %d is not a Node" % idx,
				{}
			)
		var row := _normalize_agent_row(agent_variant as Node, agent_variant.global_position, {})
		rows.append(row)
	return {
		"ok": true,
		"backend": "boids_agent_source",
		"backend_authority": "boids_spawn_safe_pass_disabled",
		"rows": rows,
	}

func _collect_agent_row(agent: Node, agent_id: String, needs_resolution: bool, world_snapshot: Dictionary, controls: Dictionary) -> Dictionary:
	var raw_position = _read_vector3(agent, "global_position", Vector3.ZERO)
	var row_position := raw_position
	var row_spawn_meta := {
		"agent_id": agent_id,
		"attempted": 0,
		"candidate_count": 0,
	}

	if needs_resolution:
		var safe = _resolve_safe_spawn_position(raw_position, agent_id, world_snapshot, controls)
		if not bool(safe.get("ok", false)):
			return {
				"ok": false,
				"error_code": safe.get("error_code", "BOID_SOURCE_NO_SAFE_SPAWN"),
				"error": String(safe.get("error_code", "BOID_SOURCE_NO_SAFE_SPAWN")),
				"error_detail": String(safe.get("error_detail", "No safe spawn found")),
			}
		row_position = safe.get("position", raw_position) as Vector3
		row_spawn_meta["attempted"] = int(safe.get("attempted", 0))
		row_spawn_meta["candidate_count"] = int(safe.get("candidate_count", 0))
		row_spawn_meta["resolve_source"] = String(safe.get("source", ""))

	_cached_positions[agent_id] = {
		"agent_id": agent_id,
		"position": row_position,
		"velocity": _read_vector3(agent, "velocity", Vector3.ZERO),
		"intent": _read_vector3(agent, "intent", Vector3.ZERO),
		"speed_hint": _read_float(agent, "forage_speed", 0.0),
		"target_goal": _read_vector3(agent, "target_goal", Vector3.ZERO),
		"target_active": _read_float(agent, "target_active", 0.0),
		"target_weight": _read_float(agent, "target_weight", 0.0),
		"avoidance_goal": _read_vector3(agent, "avoidance_goal", Vector3.ZERO),
		"avoidance_active": _read_float(agent, "avoidance_active", 0.0),
		"avoidance_weight": _read_float(agent, "avoidance_weight", 0.0),
		"flock_center": _read_vector3(agent, "flock_center", Vector3.ZERO),
		"flock_velocity": _read_vector3(agent, "flock_velocity", Vector3.ZERO),
		"spawn_meta": row_spawn_meta,
	}
	return {
		"ok": true,
		"row": _cached_positions[agent_id],
	}

func _resolve_safe_spawn_position(base_position: Vector3, agent_id: String, world_snapshot: Dictionary, controls: Dictionary) -> Dictionary:
	var attempts := max(1, int(controls["max_spawn_attempts"]))
	var base_result := _validate_spawn_position(base_position, agent_id, world_snapshot, controls)
	if bool(base_result.get("ok", false)):
		base_result["attempted"] = 0
		base_result["candidate_count"] = 1
		base_result["source"] = "base"
		return base_result

	for attempt in range(1, attempts + 1):
		var candidate_position := _deterministic_candidate_position(base_position, agent_id, attempt, controls)
		var candidate_eval := _validate_spawn_position(candidate_position, agent_id, world_snapshot, controls)
		if bool(candidate_eval.get("ok", false)):
			candidate_eval["attempted"] = attempt
			candidate_eval["candidate_count"] = attempt + 1
			candidate_eval["source"] = "candidate_%d" % attempt
			return candidate_eval

	return {
		"ok": false,
		"error_code": "BOID_SOURCE_NO_SAFE_POSITION",
		"error_detail": "No safe spawn found for %s after %d attempts." % [agent_id, attempts],
		"attempted": attempts,
		"candidate_count": attempts + 1,
	}

func _validate_spawn_position(position: Vector3, _agent_id: String, world_snapshot: Dictionary, controls: Dictionary) -> Dictionary:
	var validated_y := position.y
	if controls["require_world_clearance_proxy"]:
		var world_height_result := _query_surface_height(position.x, position.z, world_snapshot)
		if not bool(world_height_result.get("ok", false)):
			return {
				"ok": false,
				"error_code": String(world_height_result.get("error_code", "BOID_SOURCE_NO_TERRAIN_PROXY")),
				"error_detail": String(world_height_result.get("error_detail", "")),
			}

		var surface_y := float(world_height_result.get("surface_y", 0.0))
		var required_height := surface_y + float(controls["required_clearance"])
		if controls["align_spawn_to_world_clearance"]:
			validated_y = maxf(validated_y, required_height)
		elif validated_y < required_height:
			return {
				"ok": false,
				"error_code": "BOID_SOURCE_UNSAFE_CLEARANCE",
				"error_detail": "Candidate below world-clearance threshold.",
			}

		if float(controls["max_terrain_step"]) > 0.0:
			if not _terrain_step_ok(position.x, position.z, float(controls["max_terrain_step"]), world_snapshot):
				return {
					"ok": false,
					"error_code": "BOID_SOURCE_UNSAFE_STEP",
					"error_detail": "Candidate violates terrain step tolerance.",
				}
	elif controls["align_spawn_to_world_clearance"]:
		validated_y = position.y

	return {
		"ok": true,
		"position": Vector3(position.x, validated_y, position.z),
	}

func _terrain_step_ok(x: float, z: float, max_step: float, world_snapshot: Dictionary) -> bool:
	var origin := _query_surface_height(x, z, world_snapshot)
	if not bool(origin.get("ok", false)):
		return false
	var origin_height := float(origin.get("surface_y", 0.0))
	for dz in range(-1, 2):
		for dx in range(-1, 2):
			if dx == 0 and dz == 0:
				continue
			var probe := _query_surface_height(x + float(dx), z + float(dz), world_snapshot)
			if not bool(probe.get("ok", false)):
				continue
			if abs(float(probe.get("surface_y", 0.0)) - origin_height) > max_step:
				return false
	return true

func _query_surface_height(x: float, z: float, world_snapshot: Dictionary) -> Dictionary:
	var world_snapshot_variant = world_snapshot.get("voxel_world", {})
	if not world_snapshot_variant is Dictionary:
		# Allow controllers that forward world surface fields directly.
		var direct_width := int(world_snapshot.get("world_surface_width", 0))
		var direct_depth_default := int(world_snapshot.get("height", 0))
		var direct_height := int(world_snapshot.get("world_surface_depth", direct_depth_default))
		var surface_buffer = world_snapshot.get("world_surface_height", PackedInt32Array())
		if not surface_buffer is PackedInt32Array:
			return {
				"ok": false,
				"error_code": "BOID_SOURCE_NO_WORLD_SNAPSHOT",
				"error_detail": "Missing voxel_world proxy in environment snapshot."
			}
		if direct_width <= 0 or direct_height <= 0:
			return {
				"ok": false,
				"error_code": "BOID_SOURCE_INVALID_WORLD_SIZE",
				"error_detail": "Voxel world width/depth are not positive."
			}
		var direct_snapshot := {
			"width": direct_width,
			"depth": direct_height,
			"surface_y_buffer": surface_buffer,
		}
		world_snapshot_variant = direct_snapshot

	var voxel_world := world_snapshot_variant as Dictionary
	var width_default := int(world_snapshot.get("width", 0))
	var depth_default := int(world_snapshot.get("height", 0))
	var width := int(voxel_world.get("width", width_default))
	var depth := int(voxel_world.get("depth", depth_default))
	if width <= 0 or depth <= 0:
		return {
			"ok": false,
			"error_code": "BOID_SOURCE_INVALID_WORLD_SIZE",
			"error_detail": "Voxel world width/depth are not positive."
		}

	var tile_x := int(floor(x))
	var tile_z := int(floor(z))
	if tile_x < 0 or tile_x >= width or tile_z < 0 or tile_z >= depth:
		return {
			"ok": false,
			"error_code": "BOID_SOURCE_OUT_OF_BOUNDS",
			"error_detail": "Spawn sample outside world bounds."
		}

	var surface_buffer_variant := voxel_world.get("surface_y_buffer", PackedInt32Array())
	if surface_buffer_variant is PackedInt32Array:
		var surface_buffer := surface_buffer_variant as PackedInt32Array
		if surface_buffer.size() == width * depth:
			var idx := tile_z * width + tile_x
			if idx >= 0 and idx < surface_buffer.size():
				return {
					"ok": true,
					"surface_y": float(surface_buffer[idx]),
					"source": "surface_y_buffer",
				}

	var columns_variant = voxel_world.get("columns", [])
	if columns_variant is Array:
		var columns := columns_variant as Array
		var index_lookup_variant := voxel_world.get("column_index_by_tile", {})
		if index_lookup_variant is Dictionary:
			var key := "%d:%d" % [tile_x, tile_z]
			var by_tile_idx = int((index_lookup_variant as Dictionary).get(key, -1))
			if by_tile_idx >= 0 and by_tile_idx < columns.size():
				var column_variant = columns[by_tile_idx]
				if column_variant is Dictionary:
					return {
						"ok": true,
						"surface_y": float((column_variant as Dictionary).get("surface_y", 0)),
						"source": "columns[index]",
					}
		for column_variant in columns:
			if not (column_variant is Dictionary):
				continue
			var column := column_variant as Dictionary
			var col_x := int(column.get("x", -1))
			var col_z := int(column.get("z", -1))
			if col_x == tile_x and col_z == tile_z:
				return {
					"ok": true,
					"surface_y": float(column.get("surface_y", 0)),
					"source": "columns[]",
				}

	return {
		"ok": false,
		"error_code": "BOID_SOURCE_NO_TERRAIN_PROXY",
		"error_detail": "Could not resolve surface proxy for tile %d:%d." % [tile_x, tile_z],
	}

func _deterministic_candidate_position(base: Vector3, agent_id: String, attempt: int, controls: Dictionary) -> Vector3:
	var attempts_per_ring := max(1, int(controls["spawn_candidates_per_ring"]))
	var normalized_attempt := max(0, attempt)
	var ring := int(normalized_attempt / attempts_per_ring)
	var slot := int(normalized_attempt % attempts_per_ring)
	var ring_radius := float(controls["spawn_radius_min"]) + float(ring) * float(controls["spawn_radius_step"])
	var max_radius := float(controls["spawn_radius_max"])
	if max_radius > 0.0:
		ring_radius = minf(ring_radius, max_radius)
	var angle := float(_deterministic_unit(agent_id + "#" + str(controls["spawn_radius_step"]))) * TAU
	var radial_angle := angle + (TAU * float(slot) / float(attempts_per_ring))
	var x := base.x + cos(radial_angle) * ring_radius
	var z := base.z + sin(radial_angle) * ring_radius
	return Vector3(x, base.y, z)

func _resolve_world_snapshot(_controls: Dictionary) -> Dictionary:
	if not _environment_snapshot.is_empty():
		return _environment_snapshot.duplicate(true)
	if _owner != null and _owner is Object and _owner.has_method("get"):
		var candidate = _owner.get("_environment_snapshot")
		if candidate is Dictionary:
			return candidate.duplicate(true)
		if _owner.has_method("get_environment_snapshot"):
			var callback_variant = _owner.call("get_environment_snapshot")
			if callback_variant is Dictionary:
				return callback_variant.duplicate(true)
	return {}

func _resolve_controls() -> Dictionary:
	var normalized_candidates_per_ring := maxi(1, int(spawn_candidates_per_ring))
	var normalized_radius_min := maxf(0.0, float(spawn_radius_min))
	var normalized_radius_step := maxf(0.01, float(spawn_radius_step))
	var normalized_radius_max := maxf(0.0, float(spawn_radius_max))
	if normalized_radius_max < normalized_radius_min:
		normalized_radius_max = normalized_radius_min
	return {
		"source_enabled": bool(source_enabled),
		"use_spawn_lifecycle": bool(use_spawn_lifecycle),
		"spawn_resolution_interval_seconds": maxf(0.0, float(spawn_resolution_interval_seconds)),
		"max_spawn_attempts": maxi(1, int(max_spawn_attempts)),
		"spawn_candidates_per_ring": normalized_candidates_per_ring,
		"spawn_radius_min": normalized_radius_min,
		"spawn_radius_step": normalized_radius_step,
		"spawn_radius_max": normalized_radius_max,
		"required_clearance": maxf(0.0, float(required_clearance)),
		"require_world_clearance_proxy": bool(require_world_clearance_proxy),
		"max_terrain_step": maxf(0.0, float(max_terrain_step)),
		"align_spawn_to_world_clearance": bool(align_spawn_to_world_clearance),
	}

func _normalize_agent_row(agent: Node, position: Vector3, spawn_meta: Dictionary) -> Dictionary:
	return {
		"agent_id": _resolve_agent_id(agent),
		"position": position,
		"velocity": _read_vector3(agent, "velocity", Vector3.ZERO),
		"intent": _read_vector3(agent, "intent", Vector3.ZERO),
		"speed_hint": _read_float(agent, "forage_speed", 0.0),
		"target_goal": _read_vector3(agent, "target_goal", Vector3.ZERO),
		"target_active": _read_float(agent, "target_active", 0.0),
		"target_weight": _read_float(agent, "target_weight", 0.0),
		"avoidance_goal": _read_vector3(agent, "avoidance_goal", Vector3.ZERO),
		"avoidance_active": _read_float(agent, "avoidance_active", 0.0),
		"avoidance_weight": _read_float(agent, "avoidance_weight", 0.0),
		"flock_center": _read_vector3(agent, "flock_center", Vector3.ZERO),
		"flock_velocity": _read_vector3(agent, "flock_velocity", Vector3.ZERO),
		"spawn_meta": spawn_meta.duplicate(true),
	}

func _resolve_agent_id(agent: Object) -> String:
	if agent == null:
		return ""
	var direct := String(agent.get("rabbit_id")) if agent.has_method("get") else ""
	if not direct.is_empty():
		return direct
	direct = String(agent.get("agent_id")) if agent.has_method("get") else ""
	if not direct.is_empty():
		return direct
	return String(agent.name) if (agent is Node and not String(agent.name).is_empty()) else "agent_%d" % agent.get_instance_id()

func _read_float(obj: Object, property_name: StringName, fallback: float) -> float:
	if obj == null or not obj.has_method("get"):
		return fallback
	var candidate = obj.get(property_name)
	if candidate is int or candidate is float:
		return float(candidate)
	return fallback

func _read_vector3(obj: Object, property_name: StringName, fallback: Vector3) -> Vector3:
	if obj == null or not obj.has_method("get"):
		return fallback
	var candidate = obj.get(property_name)
	if candidate is Vector3:
		return candidate
	return fallback

func _deterministic_unit(value: String) -> float:
	var h := int(hash(value))
	if h < 0:
		h = -h
	return float(h % 1000000) / 1000000.0

func _error_payload(code: String, message: String, detail: String, extra: Dictionary) -> Dictionary:
	return {
		"ok": false,
		"backend": "boids_agent_source",
		"backend_authority": "boids_spawn_safe_pass_contract",
		"error": code,
		"error_code": code,
		"error_detail": "%s (%s)" % [message, detail],
		"scope_confirmation": "boids source failed safe-pass validation",
		"extra": extra.duplicate(true),
		"rows": [],
	}
