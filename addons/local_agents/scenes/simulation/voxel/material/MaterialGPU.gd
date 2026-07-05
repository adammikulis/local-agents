class_name LAMaterialGPU
extends RefCounted

## GPU compute backend for the MaterialField's hot loops (Phase 1: the heat step only).
##
## Owns a LOCAL RenderingDevice (RenderingServer.create_local_rendering_device()), the SSBOs mirroring
## the field's flat PackedFloat32Array grids, the compiled heat pipeline and its uniform set. The heat
## kernel (kernels/heat.glsl) is a race-free GATHER port of MaterialHeat.step(); this class keeps the
## CPU MaterialHeat as the correctness oracle + the headless fallback (available() is false when no
## local RenderingDevice can be made, so --headless stays on CPU). (Explicit types only — no ':='.)

const Mat: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/Materials.gd")

const HEAT_SHADER_PATH: String = "res://addons/local_agents/scenes/simulation/voxel/material/kernels/heat.glsl"
const LOCAL_SIZE_X: int = 64

var _rd: RenderingDevice = null
var _field = null                          # LAMaterialField (shared grid back-reference)
var _cell_count: int = 0

var _shader: RID = RID()
var _pipeline: RID = RID()
var _uniform_set: RID = RID()

# One SSBO per grid the heat kernel reads/writes. temp is double-buffered (in -> out) so the gather
# never reads a neighbour another invocation is writing.
var _buf_temp_in: RID = RID()
var _buf_temp_out: RID = RID()
var _buf_terrain: RID = RID()
var _buf_sampled: RID = RID()
var _buf_cloud: RID = RID()
var _buf_fog: RID = RID()
var _buf_water: RID = RID()

# _sampled is a PackedByteArray on the field; converting it to floats is the one non-native transform,
# so cache the float mirror and rebuild it only when the sampled set actually grows.
var _sampled_floats: PackedFloat32Array = PackedFloat32Array()
var _sampled_synced_count: int = -1


## True only when a local RenderingDevice can be created (false in --headless / no-compute → the caller
## keeps running the CPU MaterialHeat step). Probes with a throwaway device so it never leaks.
static func available() -> bool:
	var probe: RenderingDevice = RenderingServer.create_local_rendering_device()
	if probe == null:
		return false
	probe.free()
	return true


## Allocate the SSBOs (sized to _cell_count), compile the heat pipeline, build the uniform set.
func setup(field) -> void:
	_field = field
	_cell_count = field._cell_count
	_rd = RenderingServer.create_local_rendering_device()
	if _rd == null:
		return

	var shader_file: RDShaderFile = load(HEAT_SHADER_PATH)
	var spirv: RDShaderSPIRV = shader_file.get_spirv()
	_shader = _rd.shader_create_from_spirv(spirv)
	_pipeline = _rd.compute_pipeline_create(_shader)

	var zero: PackedFloat32Array = PackedFloat32Array()
	zero.resize(_cell_count)
	var zbytes: PackedByteArray = zero.to_byte_array()
	_buf_temp_in = _rd.storage_buffer_create(zbytes.size(), zbytes)
	_buf_temp_out = _rd.storage_buffer_create(zbytes.size(), zbytes)
	_buf_terrain = _rd.storage_buffer_create(zbytes.size(), zbytes)
	_buf_sampled = _rd.storage_buffer_create(zbytes.size(), zbytes)
	_buf_cloud = _rd.storage_buffer_create(zbytes.size(), zbytes)
	_buf_fog = _rd.storage_buffer_create(zbytes.size(), zbytes)
	_buf_water = _rd.storage_buffer_create(zbytes.size(), zbytes)

	_uniform_set = _rd.uniform_set_create(_build_uniforms(), _shader, 0)


func _make_uniform(binding: int, buf: RID) -> RDUniform:
	var u: RDUniform = RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u.binding = binding
	u.add_id(buf)
	return u


func _build_uniforms() -> Array:
	var uniforms: Array = []
	uniforms.append(_make_uniform(0, _buf_temp_in))
	uniforms.append(_make_uniform(1, _buf_temp_out))
	uniforms.append(_make_uniform(2, _buf_terrain))
	uniforms.append(_make_uniform(3, _buf_sampled))
	uniforms.append(_make_uniform(4, _buf_cloud))
	uniforms.append(_make_uniform(5, _buf_fog))
	uniforms.append(_make_uniform(6, _buf_water))
	return uniforms


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


## Rebuild + re-upload the float mirror of _sampled only when the sampled set has grown.
func _sync_sampled() -> void:
	if _field._sampled_count == _sampled_synced_count:
		return
	_sampled_synced_count = _field._sampled_count
	_sampled_floats.resize(_cell_count)
	var s: PackedByteArray = _field._sampled
	for k in range(_cell_count):
		_sampled_floats[k] = float(s[k])
	upload(_buf_sampled, _sampled_floats)


## Run one heat step on the GPU. Uploads the buffers the kernel reads, dispatches, and downloads the
## result back into _field._temp so the CPU liquid/combustion/render passes see it (Phase 1 keeps temp
## on the CPU between steps; keeping it GPU-resident is a Phase 2 optimization). `solar` == the field's
## _solar_input() (the sun energy the GPU can't read itself).
func step_heat(solar: float) -> void:
	if _rd == null:
		return
	var f = _field
	_sync_sampled()
	upload(_buf_temp_in, f._temp)
	upload(_buf_terrain, f._terrain_h)
	upload(_buf_cloud, f._cloud)
	upload(_buf_fog, f._fog)
	upload(_buf_water, f._mat_array(Mat.WATER))

	var pc: PackedByteArray = PackedByteArray()
	pc.resize(16)
	pc.encode_float(0, solar)
	pc.encode_u32(4, f._dim)
	pc.encode_u32(8, _cell_count)
	pc.encode_float(12, 0.0)

	var groups: int = int(ceil(float(_cell_count) / float(LOCAL_SIZE_X)))
	var cl: int = _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _pipeline)
	_rd.compute_list_bind_uniform_set(cl, _uniform_set, 0)
	_rd.compute_list_set_push_constant(cl, pc, pc.size())
	_rd.compute_list_dispatch(cl, groups, 1, 1)
	_rd.compute_list_end()
	_rd.submit()
	_rd.sync()

	f._temp = download(_buf_temp_out)
