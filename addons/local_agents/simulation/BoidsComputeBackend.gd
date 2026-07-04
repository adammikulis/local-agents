extends RefCounted
class_name LocalAgentsBoidsComputeBackend

const SHADER_PATH := "res://addons/local_agents/scenes/simulation/shaders/BoidsFlockCompute.glsl"
const WG_SIZE := 64
const MAX_STEP_WEIGHT := 4.0
const MAX_SPEED_LIMIT := 64.0
const MAX_FORCE_LIMIT := 16.0
const MAX_RADIUS_LIMIT := 2000.0
const MAX_CLEARANCE_LIMIT := 4096.0
const MAX_TERRAIN_LIMIT := 256.0
const MAX_ALTITUDE_LIMIT := 8192.0
const MAX_FLY_SPEED_LIMIT := 128.0
const MAX_DT := 0.05
const MIN_DT := 0.0001

var _rd: RenderingDevice
var _shader_rid: RID
var _pipeline_rid: RID
var _uniform_set_rid: RID
var _supported: bool = false
var _configured: bool = false
var _agent_count: int = 0
var _count_stride: int = 4
var _owned_rids: Array[RID] = []

var _buf_position_read: RID
var _buf_position_write: RID
var _buf_velocity_read: RID
var _buf_velocity_write: RID
var _buf_target_intent: RID
var _buf_avoid_intent: RID
var _buf_world_surface_height: RID
var _buf_params: RID
var _world_surface_width: int = 0
var _world_surface_depth: int = 0

func initialize() -> bool:
	if _supported:
		return true
	_rd = RenderingServer.create_local_rendering_device()
	if _rd == null:
		return false
	var shader_file: RDShaderFile = load(SHADER_PATH)
	if shader_file == null:
		return false
	var shader_spirv: RDShaderSPIRV = shader_file.get_spirv()
	if shader_spirv == null:
		return false
	_shader_rid = _track_rid(_rd.shader_create_from_spirv(shader_spirv))
	if not _shader_rid.is_valid():
		return false
	_pipeline_rid = _track_rid(_rd.compute_pipeline_create(_shader_rid))
	if not _pipeline_rid.is_valid():
		return false
	_supported = true
	return true


func is_supported() -> bool:
	return _supported


func is_configured() -> bool:
	return _configured and _supported and _uniform_set_rid.is_valid()


func configure(
	positions: PackedFloat32Array,
	velocities: PackedFloat32Array,
	target_intent: PackedFloat32Array = PackedFloat32Array(),
	avoidance_intent: PackedFloat32Array = PackedFloat32Array(),
	world_surface_height: PackedInt32Array = PackedInt32Array(),
	world_surface_width: int = 0,
	world_surface_depth: int = 0
) -> bool:
	if not initialize():
		return false
	if positions.is_empty() or velocities.is_empty():
		return false
	var pos_vec4 := positions.size() % _count_stride == 0
	var vel_vec4 := velocities.size() % _count_stride == 0
	var pos_vec3 := not pos_vec4 and positions.size() % 3 == 0
	var vel_vec3 := not vel_vec4 and velocities.size() % 3 == 0
	if not pos_vec4 and not pos_vec3:
		return false
	if not vel_vec4 and not vel_vec3:
		return false
	var position_count := int(positions.size() / (4 if pos_vec4 else 3))
	var velocity_count := int(velocities.size() / (4 if vel_vec4 else 3))
	if position_count != velocity_count:
		return false
	_agent_count = position_count
	var expected := _agent_count * _count_stride
	positions = _pack_vec4(positions, _agent_count, 1.0)
	velocities = _pack_vec4(velocities, _agent_count, 0.0)
	target_intent = _pack_vec4(target_intent, _agent_count, 0.0)
	avoidance_intent = _pack_vec4(avoidance_intent, _agent_count, 0.0)
	if positions.size() != expected or velocities.size() != expected:
		return false

	_free_buffers()
	_buf_position_read = _storage_buffer_from_f32(positions)
	_buf_position_write = _storage_buffer_from_f32(positions)
	_buf_velocity_read = _storage_buffer_from_f32(velocities)
	_buf_velocity_write = _storage_buffer_from_f32(velocities)
	_buf_target_intent = _storage_buffer_from_f32(target_intent)
	_buf_avoid_intent = _storage_buffer_from_f32(avoidance_intent)
	_world_surface_width = maxi(0, world_surface_width)
	_world_surface_depth = maxi(0, world_surface_depth)
	var has_world_surface_height := not world_surface_height.is_empty() and _world_surface_width > 0 and _world_surface_depth > 0
	if has_world_surface_height:
		if world_surface_height.size() != _world_surface_width * _world_surface_depth:
			return false
		_buf_world_surface_height = _storage_buffer_from_i32(world_surface_height)
	else:
		_world_surface_width = 0
		_world_surface_depth = 0
		_buf_world_surface_height = _storage_buffer_from_i32(PackedInt32Array([0]))

	_buf_params = _storage_buffer_from_f32(PackedFloat32Array([
		0.0001, # delta
		1.0, # separation_weight
		1.0, # alignment_weight
		1.0, # cohesion_weight
		0.0, # target_weight
		0.0, # avoidance_weight
		5.0, # neighbor_radius
		1.5, # separation_radius
		8.0, # max_speed
		2.0, # max_force
		0.0, # world_bounds_radius
		float(_agent_count),
		25.0, # neighbor_radius_sq
		2.25, # separation_radius_sq
		(1.0 if has_world_surface_height else 0.0), # world_surface_has_height
		float(_world_surface_width), # world_surface_width
		float(_world_surface_depth), # world_surface_depth
		0.0, # voxel_avoid_distance
		0.0, # world_avoid_weight
		0.7, # agent_radius
		1.0, # ground_clearance
		1.0, # fly_clearance
		0.0, # max_terrain_step
		0.0, # max_altitude
		0.0, # seek_high_ground
		0.0, # orbit_radius
		0.0, # orbit_rate
		0.0, # altitude_seek_weight
		0.0, # altitude_seek_target
		0.0, # flock_center_x
		0.0, # flock_center_y
		0.0, # flock_center_z
		0.0, # flock_velocity_x
		0.0, # flock_velocity_y
		0.0, # flock_velocity_z
		0.0, # max_fly_climb_speed
		0.0, # max_fly_sink_speed
	]))

	var uniforms: Array[RDUniform] = []
	uniforms.append(_ssbo_uniform(0, _buf_position_read))
	uniforms.append(_ssbo_uniform(1, _buf_velocity_read))
	uniforms.append(_ssbo_uniform(2, _buf_position_write))
	uniforms.append(_ssbo_uniform(3, _buf_velocity_write))
	uniforms.append(_ssbo_uniform(4, _buf_target_intent))
	uniforms.append(_ssbo_uniform(5, _buf_avoid_intent))
	uniforms.append(_ssbo_uniform(6, _buf_params))
	uniforms.append(_ssbo_uniform(7, _buf_world_surface_height))
	_uniform_set_rid = _track_rid(_rd.uniform_set_create(uniforms, _shader_rid, 0))
	_configured = _uniform_set_rid.is_valid()
	return _configured


func agent_count() -> int:
	return _agent_count


func step(
	delta: float,
	target_intent: PackedFloat32Array = PackedFloat32Array(),
	avoidance_intent: PackedFloat32Array = PackedFloat32Array(),
	separation_weight: float = 1.0,
	alignment_weight: float = 1.0,
	cohesion_weight: float = 1.0,
	target_weight: float = 0.0,
	avoidance_weight: float = 0.0,
	neighbor_radius: float = 5.0,
	separation_radius: float = 1.5,
	max_speed: float = 8.0,
	max_force: float = 2.0,
	world_bounds_radius: float = 0.0,
	voxel_avoid_distance: float = 0.0,
	world_avoid_weight: float = 0.0,
	agent_radius: float = 0.7,
	ground_clearance: float = 1.0,
	fly_clearance: float = 1.0,
	max_terrain_step: float = 0.0,
	max_altitude: float = 0.0,
	seek_high_ground: float = 0.0,
	orbit_radius: float = 0.0,
	orbit_rate: float = 0.0,
	altitude_seek_weight: float = 0.0,
	altitude_seek_target: float = 0.0,
	flock_center_x: float = 0.0,
	flock_center_y: float = 0.0,
	flock_center_z: float = 0.0,
	flock_velocity_x: float = 0.0,
	flock_velocity_y: float = 0.0,
	flock_velocity_z: float = 0.0,
	max_fly_climb_speed: float = 0.0,
	max_fly_sink_speed: float = 0.0,
) -> Dictionary:
	if not is_configured():
		return {
			"ok": false,
			"backend": "shader_compute",
			"error": "backend_not_configured",
			"error_code": "GPU_REQUIRED",
			"error_detail": "boids compute backend not configured",
		}
	if _agent_count <= 0:
		return {
			"ok": false,
			"backend": "shader_compute",
			"error": "no_agents",
			"error_code": "INVALID_BOIDS_SETUP",
			"error_detail": "agent_count must be positive",
		}
	var invalid_fields: Array[String] = []
	if not is_finite(delta):
		invalid_fields.append("delta")
	if not is_finite(separation_weight):
		invalid_fields.append("separation_weight")
	if not is_finite(alignment_weight):
		invalid_fields.append("alignment_weight")
	if not is_finite(cohesion_weight):
		invalid_fields.append("cohesion_weight")
	if not is_finite(target_weight):
		invalid_fields.append("target_weight")
	if not is_finite(avoidance_weight):
		invalid_fields.append("avoidance_weight")
	if not is_finite(neighbor_radius):
		invalid_fields.append("neighbor_radius")
	if not is_finite(separation_radius):
		invalid_fields.append("separation_radius")
	if not is_finite(max_speed):
		invalid_fields.append("max_speed")
	if not is_finite(max_force):
		invalid_fields.append("max_force")
	if not is_finite(world_bounds_radius):
		invalid_fields.append("world_bounds_radius")
	if not is_finite(voxel_avoid_distance):
		invalid_fields.append("voxel_avoid_distance")
	if not is_finite(world_avoid_weight):
		invalid_fields.append("world_avoid_weight")
	if not is_finite(agent_radius):
		invalid_fields.append("agent_radius")
	if not is_finite(ground_clearance):
		invalid_fields.append("ground_clearance")
	if not is_finite(fly_clearance):
		invalid_fields.append("fly_clearance")
	if not is_finite(max_terrain_step):
		invalid_fields.append("max_terrain_step")
	if not is_finite(max_altitude):
		invalid_fields.append("max_altitude")
	if not is_finite(seek_high_ground):
		invalid_fields.append("seek_high_ground")
	if not is_finite(orbit_radius):
		invalid_fields.append("orbit_radius")
	if not is_finite(orbit_rate):
		invalid_fields.append("orbit_rate")
	if not is_finite(altitude_seek_weight):
		invalid_fields.append("altitude_seek_weight")
	if not is_finite(altitude_seek_target):
		invalid_fields.append("altitude_seek_target")
	if not is_finite(flock_center_x):
		invalid_fields.append("flock_center_x")
	if not is_finite(flock_center_y):
		invalid_fields.append("flock_center_y")
	if not is_finite(flock_center_z):
		invalid_fields.append("flock_center_z")
	if not is_finite(flock_velocity_x):
		invalid_fields.append("flock_velocity_x")
	if not is_finite(flock_velocity_y):
		invalid_fields.append("flock_velocity_y")
	if not is_finite(flock_velocity_z):
		invalid_fields.append("flock_velocity_z")
	if not is_finite(max_fly_climb_speed):
		invalid_fields.append("max_fly_climb_speed")
	if not is_finite(max_fly_sink_speed):
		invalid_fields.append("max_fly_sink_speed")
	if invalid_fields.size() > 0:
		return _invalid_param_payload("invalid_step_parameters", invalid_fields)

	var safe_delta := clampf(abs(delta), MIN_DT, MAX_DT)
	var safe_separation_weight := clampf(maxf(0.0, separation_weight), 0.0, MAX_STEP_WEIGHT)
	var safe_alignment_weight := clampf(maxf(0.0, alignment_weight), 0.0, MAX_STEP_WEIGHT)
	var safe_cohesion_weight := clampf(maxf(0.0, cohesion_weight), 0.0, MAX_STEP_WEIGHT)
	var safe_target_weight := clampf(maxf(0.0, target_weight), 0.0, MAX_STEP_WEIGHT)
	var safe_avoidance_weight := clampf(maxf(0.0, avoidance_weight), 0.0, MAX_STEP_WEIGHT)
	var safe_neighbor_radius := clampf(maxf(0.0, neighbor_radius), 0.0, MAX_RADIUS_LIMIT)
	var safe_separation_radius := clampf(maxf(0.0, separation_radius), 0.0, MAX_RADIUS_LIMIT)
	var safe_max_speed := clampf(maxf(0.0001, max_speed), 0.0001, MAX_SPEED_LIMIT)
	var safe_max_force := clampf(maxf(0.0001, max_force), 0.0001, MAX_FORCE_LIMIT)
	var safe_world_bounds_radius := minf(maxf(0.0, world_bounds_radius), MAX_RADIUS_LIMIT)
	var safe_voxel_avoid_distance := maxf(0.0, voxel_avoid_distance)
	var safe_world_avoid_weight := clampf(maxf(0.0, world_avoid_weight), 0.0, MAX_STEP_WEIGHT)
	var safe_agent_radius := clampf(maxf(0.01, agent_radius), 0.01, 10.0)
	var safe_ground_clearance := clampf(maxf(0.0, ground_clearance), 0.0, MAX_CLEARANCE_LIMIT)
	var safe_fly_clearance := clampf(maxf(0.0, fly_clearance), 0.0, MAX_CLEARANCE_LIMIT)
	var safe_max_terrain_step := clampf(maxf(0.0, max_terrain_step), 0.0, MAX_TERRAIN_LIMIT)
	var safe_max_altitude := clampf(maxf(0.0, max_altitude), 0.0, MAX_ALTITUDE_LIMIT)
	var safe_seek_high_ground := clampf(seek_high_ground, 0.0, 1.0)
	var safe_orbit_radius := clampf(maxf(0.0, orbit_radius), 0.0, MAX_RADIUS_LIMIT)
	var safe_orbit_rate := clampf(maxf(0.0, orbit_rate), 0.0, MAX_STEP_WEIGHT)
	var safe_altitude_seek_weight := clampf(maxf(0.0, altitude_seek_weight), 0.0, MAX_STEP_WEIGHT)
	var safe_altitude_seek_target := maxf(0.0, altitude_seek_target)
	var safe_max_fly_climb_speed := minf(maxf(0.0, max_fly_climb_speed), MAX_FLY_SPEED_LIMIT)
	var safe_max_fly_sink_speed := minf(maxf(0.0, max_fly_sink_speed), MAX_FLY_SPEED_LIMIT)
	var safe_flock_center_x := flock_center_x
	var safe_flock_center_y := flock_center_y
	var safe_flock_center_z := flock_center_z
	var safe_flock_velocity_x := flock_velocity_x
	var safe_flock_velocity_y := flock_velocity_y
	var safe_flock_velocity_z := flock_velocity_z

	var target_payload := _pack_vec4(target_intent, _agent_count, 0.0)
	var avoid_payload := _pack_vec4(avoidance_intent, _agent_count, 0.0)
	var target_bytes := target_payload.to_byte_array()
	var avoid_bytes := avoid_payload.to_byte_array()
	_rd.buffer_update(_buf_target_intent, 0, target_bytes.size(), target_bytes)
	_rd.buffer_update(_buf_avoid_intent, 0, avoid_bytes.size(), avoid_bytes)

	var neighbor_radius_sq := safe_neighbor_radius * safe_neighbor_radius
	var separation_radius_sq := safe_separation_radius * safe_separation_radius
	var params := PackedFloat32Array([
		safe_delta,
		safe_separation_weight,
		safe_alignment_weight,
		safe_cohesion_weight,
		safe_target_weight,
		safe_avoidance_weight,
		safe_neighbor_radius,
		maxf(0.0001, safe_separation_radius),
		safe_max_speed,
		safe_max_force,
		safe_world_bounds_radius,
		float(_agent_count),
		maxf(0.0, neighbor_radius_sq),
		maxf(0.0001, separation_radius_sq),
		(1.0 if _world_surface_width > 0 and _world_surface_depth > 0 else 0.0),
		float(_world_surface_width),
		float(_world_surface_depth),
		safe_voxel_avoid_distance,
		safe_world_avoid_weight,
		safe_agent_radius,
		safe_ground_clearance,
		safe_fly_clearance,
		safe_max_terrain_step,
		safe_max_altitude,
		safe_seek_high_ground,
		safe_orbit_radius,
		safe_orbit_rate,
		safe_altitude_seek_weight,
		safe_altitude_seek_target,
		safe_flock_center_x,
		safe_flock_center_y,
		safe_flock_center_z,
		safe_flock_velocity_x,
		safe_flock_velocity_y,
		safe_flock_velocity_z,
		safe_max_fly_climb_speed,
		safe_max_fly_sink_speed,
	])
	for i in range(params.size()):
		if not is_finite(params[i]):
			params[i] = 0.0
	var params_bytes := params.to_byte_array()
	_rd.buffer_update(_buf_params, 0, params_bytes.size(), params_bytes)

	var list_id = _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(list_id, _pipeline_rid)
	_rd.compute_list_bind_uniform_set(list_id, _uniform_set_rid, 0)
	var groups := int(ceil(float(_agent_count) / float(WG_SIZE)))
	_rd.compute_list_dispatch(list_id, groups, 1, 1)
	_rd.compute_list_end()
	_rd.submit()
	_rd.sync()

	_swap_state_buffers()
	var snapshot := _snapshot_state()
	snapshot["ok"] = true
	snapshot["backend"] = "shader_compute"
	snapshot["error"] = ""
	snapshot["error_code"] = ""
	snapshot["error_detail"] = ""
	return snapshot


func _invalid_param_payload(error_detail: String, invalid_fields: Array[String]) -> Dictionary:
	return {
		"ok": false,
		"backend": "shader_compute",
		"error": "invalid_step_parameters",
		"error_code": "INVALID_BOIDS_PARAMS",
		"error_detail": error_detail,
		"invalid_fields": invalid_fields,
	}


func release() -> void:
	_free_buffers()
	_pipeline_rid = _release_rid(_pipeline_rid)
	_shader_rid = _release_rid(_shader_rid)
	_owned_rids.clear()
	_rd = null
	_configured = false
	_supported = false
	_agent_count = 0


func _snapshot_state() -> Dictionary:
	if _rd == null or _agent_count <= 0:
		return {}
	return {
		"positions": _rd.buffer_get_data(_buf_position_read).to_float32_array(),
		"velocities": _rd.buffer_get_data(_buf_velocity_read).to_float32_array(),
		"agent_count": _agent_count,
	}


func _pack_vec4(values: PackedFloat32Array, agent_count: int, default_w: float) -> PackedFloat32Array:
	var expected := agent_count * _count_stride
	var out := PackedFloat32Array()
	out.resize(expected)
	for i in range(agent_count):
		var out_base := i * _count_stride
		out[out_base + 3] = default_w
	if values.size() == expected:
		for i in range(expected):
			out[i] = values[i]
		return out
	if values.size() == agent_count * 3:
		for i in range(agent_count):
			var in_base := i * 3
			var out_base := i * _count_stride
			out[out_base] = values[in_base]
			out[out_base + 1] = values[in_base + 1]
			out[out_base + 2] = values[in_base + 2]
		return out
	var copy_count := mini(values.size(), expected)
	for i in range(copy_count):
		out[i] = values[i]
	return out


func _free_buffers() -> void:
	if _rd == null:
		_uniform_set_rid = RID()
		_buf_position_read = RID()
		_buf_position_write = RID()
		_buf_velocity_read = RID()
		_buf_velocity_write = RID()
		_buf_target_intent = RID()
		_buf_avoid_intent = RID()
		_buf_params = RID()
		_buf_world_surface_height = RID()
		_world_surface_width = 0
		_world_surface_depth = 0
		_configured = false
		return
	if _uniform_set_rid.is_valid():
		_uniform_set_rid = _release_rid(_uniform_set_rid)
	_buf_position_read = _release_rid(_buf_position_read)
	_buf_position_write = _release_rid(_buf_position_write)
	_buf_velocity_read = _release_rid(_buf_velocity_read)
	_buf_velocity_write = _release_rid(_buf_velocity_write)
	_buf_target_intent = _release_rid(_buf_target_intent)
	_buf_avoid_intent = _release_rid(_buf_avoid_intent)
	_buf_params = _release_rid(_buf_params)
	_buf_world_surface_height = _release_rid(_buf_world_surface_height)
	_world_surface_width = 0
	_world_surface_depth = 0
	_configured = false


func _swap_state_buffers() -> void:
	var next_pos = _buf_position_read
	_buf_position_read = _buf_position_write
	_buf_position_write = next_pos
	var next_vel = _buf_velocity_read
	_buf_velocity_read = _buf_velocity_write
	_buf_velocity_write = next_vel


func _storage_buffer_from_f32(data: PackedFloat32Array) -> RID:
	if _rd == null:
		return RID()
	var bytes = data.to_byte_array()
	var rid = _rd.storage_buffer_create(bytes.size(), bytes)
	if rid.is_valid() and not _owned_rids.has(rid):
		_owned_rids.append(rid)
	return rid


func _storage_buffer_from_i32(data: PackedInt32Array) -> RID:
	if _rd == null:
		return RID()
	var bytes = data.to_byte_array()
	var rid = _rd.storage_buffer_create(bytes.size(), bytes)
	if rid.is_valid() and not _owned_rids.has(rid):
		_owned_rids.append(rid)
	return rid


func _ssbo_uniform(binding: int, rid: RID) -> RDUniform:
	var out := RDUniform.new()
	out.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	out.binding = binding
	out.add_id(rid)
	return out


func _track_rid(rid: RID) -> RID:
	if rid.is_valid() and not _owned_rids.has(rid):
		_owned_rids.append(rid)
	return rid


func _release_rid(rid: RID) -> RID:
	if _rd == null or not rid.is_valid():
		return RID()
	if not _owned_rids.has(rid):
		return RID()
	for i in range(_owned_rids.size() - 1, -1, -1):
		if _owned_rids[i] == rid:
			_owned_rids.remove_at(i)
			_rd.free_rid(rid)
			break
	return RID()
