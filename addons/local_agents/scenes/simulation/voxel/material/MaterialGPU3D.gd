class_name LAMaterialGPU3D
extends RefCounted

## GPU compute backend for the DENSE 3D MaterialField3D's two hottest per-cell loops — the successor of
## the 2.5D LAMaterialGPU, mirroring its structure exactly. Owns a LOCAL RenderingDevice
## (RenderingServer.create_local_rendering_device()), the SSBOs mirroring the field's flat 3D grids, the
## compiled compute pipelines and their uniform sets. The kernels are race-free GATHER / double-buffered
## ports of the CPU oracle in MaterialField3D.gd + MaterialHeat3D.gd:
##   - kernels3d/heat3d.glsl  <- MaterialHeat3D.step() PART 1 (6-neighbour conduction toward the mean)
##   - kernels3d/water3d.glsl <- MaterialField3D.step_water() (down / lateral level-out / up overflow)
##
## The CPU GDScript loops stay the correctness ORACLE + headless fallback: available() is false when no
## local RenderingDevice can be made (--headless / no-compute), so those environments keep running the
## CPU rules. Solar / ambient / buoyancy / wet-cell cooling stay on the CPU after the GPU heat
## conduction pass (conduction is the heavy loop); this file ports ONLY the dominant per-cell work.
##
## Index layout (matches MaterialField3D): idx = (iy * dim_z + iz) * dim_x + ix  (X contiguous, then Z,
## then Y). Dispatch is a flat 1D dispatch over cell_count; the kernels decode ix/iy/iz from the flat
## index (same as the 2.5D backend). (Explicit types only — no ':=' inferred typing.)

const HEAT_SHADER_PATH: String = "res://addons/local_agents/scenes/simulation/voxel/material/kernels3d/heat3d.glsl"
const WATER_SHADER_PATH: String = "res://addons/local_agents/scenes/simulation/voxel/material/kernels3d/water3d.glsl"
const LOCAL_SIZE_X: int = 64

var _rd: RenderingDevice = null
var _field = null                          # LAMaterialField3D (shared grid back-reference)
var _cell_count: int = 0
var _dim_x: int = 0
var _dim_y: int = 0
var _dim_z: int = 0

var _heat_shader: RID = RID()
var _heat_pipeline: RID = RID()
var _heat_set: RID = RID()

# One shader, dispatched twice with a `pass_id` push-constant: pass 0 = outflow (each cell writes its
# per-direction sends), a barrier, then pass 1 = inflow/apply (each cell gathers the sends aimed at it).
# This two-pass gather is the race-free equivalent of the CPU sequential scatter in step_water().
var _water_shader: RID = RID()
var _water_pipeline: RID = RID()
var _water_set: RID = RID()

# Persistent SSBOs (sized to _cell_count). temp is double-buffered (in -> out) so the heat gather never
# reads a neighbour another invocation is writing; water uses in/out + a 6-float-per-cell send scratch.
var _buf_temp_in: RID = RID()
var _buf_temp_out: RID = RID()
var _buf_water_in: RID = RID()
var _buf_water_out: RID = RID()
var _buf_solid: RID = RID()                # byte->float mirror of _solid (1 = rock)
var _buf_static: RID = RID()               # byte->float mirror of _static (1 = calm sea sink)
var _buf_send: RID = RID()                 # cell_count * 6 floats: per-direction outflow


## True only when a local RenderingDevice can be created (false in --headless / no-compute → the caller
## keeps running the CPU modules). Probes with a throwaway device so it never leaks.
static func available() -> bool:
	var probe: RenderingDevice = RenderingServer.create_local_rendering_device()
	if probe == null:
		return false
	probe.free()
	return true


## Create the RenderingDevice + pipelines and size the SSBOs to the field's cell_count. Safe to skip
## calling (the step methods lazily init) — provided to mirror the 2.5D backend's setup(field).
func setup(field) -> void:
	_field = field
	_init_rd()
	if _rd == null:
		return
	_ensure_buffers(field._dim_x, field._dim_y, field._dim_z)


func _init_rd() -> void:
	if _rd != null:
		return
	_rd = RenderingServer.create_local_rendering_device()
	if _rd == null:
		return
	_heat_shader = _compile(HEAT_SHADER_PATH)
	_heat_pipeline = _rd.compute_pipeline_create(_heat_shader)
	_water_shader = _compile(WATER_SHADER_PATH)
	_water_pipeline = _rd.compute_pipeline_create(_water_shader)


func _compile(path: String) -> RID:
	var shader_file: RDShaderFile = load(path)
	var spirv: RDShaderSPIRV = shader_file.get_spirv()
	return _rd.shader_create_from_spirv(spirv)


func _make_uniform(binding: int, buf: RID) -> RDUniform:
	var u: RDUniform = RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u.binding = binding
	u.add_id(buf)
	return u


## (Re)allocate the SSBOs + uniform sets when the volume size changes. Idempotent for a fixed size.
func _ensure_buffers(dim_x: int, dim_y: int, dim_z: int) -> void:
	if _rd == null:
		return
	var cell_count: int = dim_x * dim_y * dim_z
	if cell_count == _cell_count and _buf_temp_in.is_valid():
		_dim_x = dim_x
		_dim_y = dim_y
		_dim_z = dim_z
		return
	_free_buffers()
	_cell_count = cell_count
	_dim_x = dim_x
	_dim_y = dim_y
	_dim_z = dim_z

	var zero: PackedFloat32Array = PackedFloat32Array()
	zero.resize(cell_count)
	var zbytes: PackedByteArray = zero.to_byte_array()
	_buf_temp_in = _rd.storage_buffer_create(zbytes.size(), zbytes)
	_buf_temp_out = _rd.storage_buffer_create(zbytes.size(), zbytes)
	_buf_water_in = _rd.storage_buffer_create(zbytes.size(), zbytes)
	_buf_water_out = _rd.storage_buffer_create(zbytes.size(), zbytes)
	_buf_solid = _rd.storage_buffer_create(zbytes.size(), zbytes)
	_buf_static = _rd.storage_buffer_create(zbytes.size(), zbytes)
	var send_zero: PackedFloat32Array = PackedFloat32Array()
	send_zero.resize(cell_count * 6)
	var send_bytes: PackedByteArray = send_zero.to_byte_array()
	_buf_send = _rd.storage_buffer_create(send_bytes.size(), send_bytes)

	# Heat uniform set (binding order matches heat3d.glsl).
	var hu: Array = []
	hu.append(_make_uniform(0, _buf_temp_in))
	hu.append(_make_uniform(1, _buf_temp_out))
	_heat_set = _rd.uniform_set_create(hu, _heat_shader, 0)

	# Water uniform set (binding order matches water3d.glsl; one set reused for both passes).
	var wu: Array = []
	wu.append(_make_uniform(0, _buf_water_in))
	wu.append(_make_uniform(1, _buf_solid))
	wu.append(_make_uniform(2, _buf_static))
	wu.append(_make_uniform(3, _buf_send))
	wu.append(_make_uniform(4, _buf_water_out))
	_water_set = _rd.uniform_set_create(wu, _water_shader, 0)


func _free_buffers() -> void:
	if _rd == null:
		return
	if _heat_set.is_valid():
		_rd.free_rid(_heat_set)
		_heat_set = RID()
	if _water_set.is_valid():
		_rd.free_rid(_water_set)
		_water_set = RID()
	for buf in [_buf_temp_in, _buf_temp_out, _buf_water_in, _buf_water_out, _buf_solid, _buf_static, _buf_send]:
		if buf.is_valid():
			_rd.free_rid(buf)
	_buf_temp_in = RID()
	_buf_temp_out = RID()
	_buf_water_in = RID()
	_buf_water_out = RID()
	_buf_solid = RID()
	_buf_static = RID()
	_buf_send = RID()
	_cell_count = 0


## Upload a flat grid into an SSBO (native byte copy).
func upload(buf: RID, arr: PackedFloat32Array) -> void:
	if _rd == null:
		return
	var bytes: PackedByteArray = arr.to_byte_array()
	_rd.buffer_update(buf, 0, bytes.size(), bytes)


## Download an SSBO back to a flat grid.
func download(buf: RID) -> PackedFloat32Array:
	if _rd == null:
		return PackedFloat32Array()
	var bytes: PackedByteArray = _rd.buffer_get_data(buf)
	return bytes.to_float32_array()


func _bytes_to_floats(b: PackedByteArray) -> PackedFloat32Array:
	var out: PackedFloat32Array = PackedFloat32Array()
	out.resize(b.size())
	for k in range(b.size()):
		out[k] = float(b[k])
	return out


func _groups() -> int:
	return int(ceil(float(_cell_count) / float(LOCAL_SIZE_X)))


## Run one 6-neighbour heat CONDUCTION pass on the GPU (MaterialHeat3D.step() part 1). `temp` is the
## current per-cell temperature grid; `solid` is accepted for API symmetry but conduction does NOT read
## it (the CPU oracle also relaxes every cell — rock and void — toward its in-bounds neighbour mean).
## `dims` = Vector3i(dim_x, dim_y, dim_z). Returns the new temperature grid. The CPU then applies
## solar / ambient / buoyancy / wet-cooling to this result.
func step_heat_conduction(temp: PackedFloat32Array, solid: PackedByteArray, dims: Vector3i) -> PackedFloat32Array:
	_init_rd()
	if _rd == null:
		return PackedFloat32Array()
	_ensure_buffers(dims.x, dims.y, dims.z)
	upload(_buf_temp_in, temp)

	var pc: PackedByteArray = PackedByteArray()
	pc.resize(16)
	pc.encode_u32(0, dims.x)
	pc.encode_u32(4, dims.y)
	pc.encode_u32(8, dims.z)
	pc.encode_u32(12, _cell_count)

	var groups: int = _groups()
	var cl: int = _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _heat_pipeline)
	_rd.compute_list_bind_uniform_set(cl, _heat_set, 0)
	_rd.compute_list_set_push_constant(cl, pc, pc.size())
	_rd.compute_list_dispatch(cl, groups, 1, 1)
	_rd.compute_list_end()
	_rd.submit()
	_rd.sync()

	return download(_buf_temp_out)


## Run one water CA step on the GPU (MaterialField3D.step_water()): gravity DOWN, lateral level-out to
## the 4 XZ neighbours, UP overflow — mass-conserving, with static cells as infinite sinks (absorb).
## Two-pass gather (outflow -> barrier -> inflow/apply) is the race-free equivalent of the CPU
## sequential scatter. `dims` = Vector3i(dim_x, dim_y, dim_z). Returns the new water grid.
func flow_water(water: PackedFloat32Array, solid: PackedByteArray, static_cells: PackedByteArray, dims: Vector3i) -> PackedFloat32Array:
	_init_rd()
	if _rd == null:
		return PackedFloat32Array()
	_ensure_buffers(dims.x, dims.y, dims.z)
	upload(_buf_water_in, water)
	upload(_buf_solid, _bytes_to_floats(solid))
	upload(_buf_static, _bytes_to_floats(static_cells))

	var groups: int = _groups()
	var cl: int = _rd.compute_list_begin()

	# Pass 0: per-cell per-direction outflow into the send buffer.
	_rd.compute_list_bind_compute_pipeline(cl, _water_pipeline)
	_rd.compute_list_bind_uniform_set(cl, _water_set, 0)
	_rd.compute_list_set_push_constant(cl, _water_pc(dims, 0), 32)
	_rd.compute_list_dispatch(cl, groups, 1, 1)

	# Pass 1 reads the sends written by pass 0 — barrier so they are visible, then gather + apply.
	_rd.compute_list_add_barrier(cl)
	_rd.compute_list_bind_compute_pipeline(cl, _water_pipeline)
	_rd.compute_list_bind_uniform_set(cl, _water_set, 0)
	_rd.compute_list_set_push_constant(cl, _water_pc(dims, 1), 32)
	_rd.compute_list_dispatch(cl, groups, 1, 1)

	_rd.compute_list_end()
	_rd.submit()
	_rd.sync()

	return download(_buf_water_out)


func _water_pc(dims: Vector3i, pass_id: int) -> PackedByteArray:
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(32)
	pc.encode_u32(0, dims.x)
	pc.encode_u32(4, dims.y)
	pc.encode_u32(8, dims.z)
	pc.encode_u32(12, _cell_count)
	pc.encode_u32(16, pass_id)
	pc.encode_u32(20, 0)
	pc.encode_u32(24, 0)
	pc.encode_u32(28, 0)
	return pc
