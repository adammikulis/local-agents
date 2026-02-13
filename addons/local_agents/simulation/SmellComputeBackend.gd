extends RefCounted
class_name LocalAgentsSmellComputeBackend

const SHADER_PATH := "res://addons/local_agents/scenes/simulation/shaders/SmellFieldCompute.glsl"
const WG_SIZE := 64
const OUTPUT_SLOTS_PER_SOURCE := 7

var _rd: RenderingDevice
var _shader_rid: RID
var _pipeline_rid: RID
var _supported: bool = false

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
	_shader_rid = _rd.shader_create_from_spirv(shader_spirv)
	if not _shader_rid.is_valid():
		return false
	_pipeline_rid = _rd.compute_pipeline_create(_shader_rid)
	if not _pipeline_rid.is_valid():
		return false
	_supported = true
	return true

func is_supported() -> bool:
	return _supported

func step(
	source_voxels: Array[Vector3i],
	source_values: PackedFloat32Array,
	wind_x: PackedFloat32Array,
	wind_y: PackedFloat32Array,
	touched_mask: PackedInt32Array,
	grid_radius_cells: int,
	vertical_cells: int,
	local_mode: bool,
	delta: float,
	decay_factor: float,
	voxel_size: float,
	half_extent: float,
	vertical_half_extent: float
) -> Dictionary:
	if not _supported:
		return {}
	var count := source_voxels.size()
	if count <= 0:
		return {}
	if source_values.size() != count or wind_x.size() != count or wind_y.size() != count:
		return {}
	var src_x := PackedInt32Array()
	var src_y := PackedInt32Array()
	var src_z := PackedInt32Array()
	src_x.resize(count)
	src_y.resize(count)
	src_z.resize(count)
	for i in range(count):
		var v: Vector3i = source_voxels[i]
		src_x[i] = v.x
		src_y[i] = v.y
		src_z[i] = v.z
	var out_count := count * OUTPUT_SLOTS_PER_SOURCE
	var out_x := PackedInt32Array()
	var out_y := PackedInt32Array()
	var out_z := PackedInt32Array()
	var out_values := PackedFloat32Array()
	out_x.resize(out_count)
	out_y.resize(out_count)
	out_z.resize(out_count)
	out_values.resize(out_count)
	var params := PackedFloat32Array([
		maxf(0.0001, delta),
		clampf(decay_factor, 0.0, 1.0),
		maxf(0.0001, half_extent),
		maxf(0.0001, voxel_size),
		maxf(voxel_size, vertical_half_extent),
		1.0 if local_mode else 0.0,
		float(maxi(0, grid_radius_cells)),
		float(maxi(0, vertical_cells)),
		float(count),
	])
	var buffers := _create_step_buffers(src_x, src_y, src_z, source_values, wind_x, wind_y, touched_mask, out_x, out_y, out_z, out_values, params)
	if buffers.is_empty():
		return {}
	var uniforms: Array[RDUniform] = []
	uniforms.append(_ssbo_uniform(0, buffers["src_x"]))
	uniforms.append(_ssbo_uniform(1, buffers["src_y"]))
	uniforms.append(_ssbo_uniform(2, buffers["src_z"]))
	uniforms.append(_ssbo_uniform(3, buffers["src_value"]))
	uniforms.append(_ssbo_uniform(4, buffers["wind_x"]))
	uniforms.append(_ssbo_uniform(5, buffers["wind_y"]))
	uniforms.append(_ssbo_uniform(6, buffers["touched_mask"]))
	uniforms.append(_ssbo_uniform(7, buffers["out_x"]))
	uniforms.append(_ssbo_uniform(8, buffers["out_y"]))
	uniforms.append(_ssbo_uniform(9, buffers["out_z"]))
	uniforms.append(_ssbo_uniform(10, buffers["out_value"]))
	uniforms.append(_ssbo_uniform(11, buffers["params"]))
	var uniform_set := _rd.uniform_set_create(uniforms, _shader_rid, 0)
	if not uniform_set.is_valid():
		_free_step_buffers(buffers)
		return {}
	var list_id = _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(list_id, _pipeline_rid)
	_rd.compute_list_bind_uniform_set(list_id, uniform_set, 0)
	var groups = int(ceil(float(count) / float(WG_SIZE)))
	_rd.compute_list_dispatch(list_id, groups, 1, 1)
	_rd.compute_list_end()
	_rd.submit()
	_rd.sync()
	var result := {
		"out_x": _rd.buffer_get_data(buffers["out_x"]).to_int32_array(),
		"out_y": _rd.buffer_get_data(buffers["out_y"]).to_int32_array(),
		"out_z": _rd.buffer_get_data(buffers["out_z"]).to_int32_array(),
		"out_value": _rd.buffer_get_data(buffers["out_value"]).to_float32_array(),
	}
	_rd.free_rid(uniform_set)
	_free_step_buffers(buffers)
	return result

func release() -> void:
	if _rd != null:
		if _pipeline_rid.is_valid():
			_rd.free_rid(_pipeline_rid)
		if _shader_rid.is_valid():
			_rd.free_rid(_shader_rid)
	_pipeline_rid = RID()
	_shader_rid = RID()
	_supported = false

func _create_step_buffers(
	src_x: PackedInt32Array,
	src_y: PackedInt32Array,
	src_z: PackedInt32Array,
	src_value: PackedFloat32Array,
	wind_x: PackedFloat32Array,
	wind_y: PackedFloat32Array,
	touched_mask: PackedInt32Array,
	out_x: PackedInt32Array,
	out_y: PackedInt32Array,
	out_z: PackedInt32Array,
	out_value: PackedFloat32Array,
	params: PackedFloat32Array
) -> Dictionary:
	if _rd == null:
		return {}
	return {
		"src_x": _storage_buffer_from_i32(src_x),
		"src_y": _storage_buffer_from_i32(src_y),
		"src_z": _storage_buffer_from_i32(src_z),
		"src_value": _storage_buffer_from_f32(src_value),
		"wind_x": _storage_buffer_from_f32(wind_x),
		"wind_y": _storage_buffer_from_f32(wind_y),
		"touched_mask": _storage_buffer_from_i32(touched_mask),
		"out_x": _storage_buffer_from_i32(out_x),
		"out_y": _storage_buffer_from_i32(out_y),
		"out_z": _storage_buffer_from_i32(out_z),
		"out_value": _storage_buffer_from_f32(out_value),
		"params": _storage_buffer_from_f32(params),
	}

func _free_step_buffers(buffers: Dictionary) -> void:
	if _rd == null:
		return
	for key_variant in buffers.keys():
		var key := String(key_variant)
		var rid: RID = buffers[key]
		if rid.is_valid():
			_rd.free_rid(rid)

func _storage_buffer_from_f32(data: PackedFloat32Array) -> RID:
	var bytes := data.to_byte_array()
	return _rd.storage_buffer_create(bytes.size(), bytes)

func _storage_buffer_from_i32(data: PackedInt32Array) -> RID:
	var bytes := data.to_byte_array()
	return _rd.storage_buffer_create(bytes.size(), bytes)

func _ssbo_uniform(binding: int, rid: RID) -> RDUniform:
	var out := RDUniform.new()
	out.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	out.binding = binding
	out.add_id(rid)
	return out
