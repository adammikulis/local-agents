class_name LAMaterialSphereGPU3D
extends RefCounted

## Cubed-sphere GPU field driver (Phase B integration). Drop-in for LAMaterialGPU3D when the field is a
## planet (`MaterialField3D.is_sphere()`): same 8-method contract (setup/begin_frame/step/end_frame/set_field/
## set_precip/set_prevailing/set_raining) so `MaterialField3D`'s step path is unchanged. Runs the GPU-PROVEN
## cubed-sphere kernels over the SphereGrid's neighbour SSBO (heat conduction + the water CA to start; more
## kernels slot in one dispatch at a time). MVP scope: temp + water step on the sphere; other channels echo
## unchanged (empty readback → field skips scatter). Modelled on the verified spike_gpu_* harnesses.

const HEAT_PATH: String = "res://addons/local_agents/scenes/simulation/voxel/material/kernels3d/heat_sphere3d.glsl"
const WATER_PATH: String = "res://addons/local_agents/scenes/simulation/voxel/material/kernels3d/water_sphere3d.glsl"

static func available() -> bool:
	var rd: RenderingDevice = RenderingServer.create_local_rendering_device()
	if rd == null:
		return false
	rd.free()
	return true

var _rd: RenderingDevice = null
var _field = null
var _grid: RefCounted = null
var _cc: int = 0
var _parity: int = 0

var _heat_pipe: RID = RID()
var _water_pipe: RID = RID()
var _heat_shader: RID = RID()
var _water_shader: RID = RID()

var _temp: Array = [RID(), RID()]       # ping-pong
var _water: Array = [RID(), RID()]
var _solid: RID = RID()
var _static: RID = RID()
var _send: RID = RID()
var _nbr: RID = RID()
var _send_bytes: int = 0

var _heat_set: Array = [RID(), RID()]   # per parity
var _water_set: Array = [RID(), RID()]
var _groups: int = 0


func setup(field) -> void:
	_field = field
	_grid = field.sphere_grid()
	_cc = field._cell_count
	_rd = RenderingServer.create_local_rendering_device()
	if _rd == null:
		push_error("LAMaterialSphereGPU3D: no RenderingDevice")
		return

	var heat_sf: RDShaderFile = load(HEAT_PATH)
	_heat_shader = _rd.shader_create_from_spirv(heat_sf.get_spirv())
	_heat_pipe = _rd.compute_pipeline_create(_heat_shader)
	var water_sf: RDShaderFile = load(WATER_PATH)
	_water_shader = _rd.shader_create_from_spirv(water_sf.get_spirv())
	_water_pipe = _rd.compute_pipeline_create(_water_shader)

	var z: PackedByteArray = _zeros(_cc)
	_temp[0] = _rd.storage_buffer_create(z.size(), z)
	_temp[1] = _rd.storage_buffer_create(z.size(), _zeros(_cc))
	_water[0] = _rd.storage_buffer_create(z.size(), _zeros(_cc))
	_water[1] = _rd.storage_buffer_create(z.size(), _zeros(_cc))
	_solid = _rd.storage_buffer_create(z.size(), _zeros(_cc))
	_static = _rd.storage_buffer_create(z.size(), _zeros(_cc))
	_send_bytes = _cc * 6 * 4
	_send = _rd.storage_buffer_create(_send_bytes, _zeros(_cc * 6))
	var nbr_bytes: PackedByteArray = _grid.neighbours_kernel_order().to_byte_array()
	_nbr = _rd.storage_buffer_create(nbr_bytes.size(), nbr_bytes)

	for p in 2:
		_heat_set[p] = _rd.uniform_set_create(
			[_u(0, _temp[p]), _u(1, _temp[1 - p]), _u(15, _nbr)], _heat_shader, 0)
		_water_set[p] = _rd.uniform_set_create(
			[_u(0, _water[p]), _u(1, _solid), _u(2, _static), _u(3, _send), _u(4, _water[1 - p]), _u(15, _nbr)],
			_water_shader, 0)
	_groups = int(ceil(float(_cc) / 64.0))


# --- Frame API (matches LAMaterialGPU3D so MaterialField3D's step path is unchanged) ------------------------

func begin_frame(temp: PackedFloat32Array, water: PackedFloat32Array, _solar: float = 0.6, _wind: Vector2 = Vector2.ZERO) -> void:
	if _rd == null:
		return
	_upload(_temp[_parity], temp)
	_upload(_water[_parity], water)
	# Refresh solid/static from the field (terrain sampling fills these over the first frames).
	_upload_bytes(_solid, _field._solid)
	_upload_bytes(_static, _field._static)

func step() -> void:
	if _rd == null:
		return
	var back: int = 1 - _parity
	# Heat conduction: temp[parity] -> temp[back]
	_dispatch(_heat_pipe, _heat_set[_parity], _pc4(_cc, 0))
	# Water CA (2-pass): fresh send scratch, pass 0 outflow, pass 1 inflow → water[back]
	_rd.buffer_clear(_send, 0, _send_bytes)
	_dispatch(_water_pipe, _water_set[_parity], _pc4(_cc, 0))
	_dispatch(_water_pipe, _water_set[_parity], _pc4(_cc, 1))
	_rd.submit()
	_rd.sync()
	_parity = back

func end_frame(_rv: bool = true, _rc: bool = true, _rf: bool = true, _rr: bool = true, _rl: bool = true, _rs: bool = true) -> Dictionary:
	var out: Dictionary = _empty_result()
	if _rd == null:
		return out
	out["temp"] = _rd.buffer_get_data(_temp[_parity]).to_float32_array()
	out["water"] = _rd.buffer_get_data(_water[_parity]).to_float32_array()
	return out

func set_field(name: String, arr) -> void:
	if _rd == null:
		return
	match name:
		"temp":
			_upload(_temp[_parity], arr)
		"water":
			_upload(_water[_parity], arr)
	# other channels: not yet stepped on the sphere (echo unchanged) — no-op

func set_precip(_v: float) -> void:
	pass

func set_prevailing(_v: Vector2) -> void:
	pass

func set_raining(_v: bool) -> void:
	pass


# --- helpers ------------------------------------------------------------------

func _dispatch(pipe: RID, uset: RID, pc: PackedByteArray) -> void:
	var cl: int = _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, pipe)
	_rd.compute_list_bind_uniform_set(cl, uset, 0)
	_rd.compute_list_set_push_constant(cl, pc, pc.size())
	_rd.compute_list_dispatch(cl, _groups, 1, 1)
	_rd.compute_list_end()

func _u(binding: int, buf: RID) -> RDUniform:
	var u: RDUniform = RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u.binding = binding
	u.add_id(buf)
	return u

func _pc4(a: int, b: int) -> PackedByteArray:
	return PackedInt32Array([a, b, 0, 0]).to_byte_array()

func _upload(buf: RID, arr: PackedFloat32Array) -> void:
	if arr.size() == _cc:
		var b: PackedByteArray = arr.to_byte_array()
		_rd.buffer_update(buf, 0, b.size(), b)

func _upload_bytes(buf: RID, arr: PackedByteArray) -> void:
	# byte mask (solid/static) → float buffer the kernels read as 0/1
	if arr.size() == _cc:
		var f: PackedFloat32Array = PackedFloat32Array()
		f.resize(_cc)
		for i in _cc:
			f[i] = 1.0 if arr[i] != 0 else 0.0
		var b: PackedByteArray = f.to_byte_array()
		_rd.buffer_update(buf, 0, b.size(), b)

func _zeros(n: int) -> PackedByteArray:
	var a: PackedFloat32Array = PackedFloat32Array()
	a.resize(n)
	return a.to_byte_array()

func _empty_result() -> Dictionary:
	return {
		"temp": PackedFloat32Array(), "water": PackedFloat32Array(),
		"vapor": PackedFloat32Array(), "cloud": PackedFloat32Array(),
		"fog": PackedFloat32Array(), "lava": PackedFloat32Array(),
		"fire": PackedFloat32Array(), "fuel": PackedFloat32Array(),
		"sediment": PackedFloat32Array(), "o2": PackedFloat32Array(),
		"co2": PackedFloat32Array(), "charge": PackedFloat32Array(),
		"scent": PackedFloat32Array(), "fert": PackedFloat32Array(),
		"detritus": PackedFloat32Array(), "shock": PackedFloat32Array(),
		"dust": PackedFloat32Array(), "snow": PackedFloat32Array(),
		"susp": PackedFloat32Array(),
	}
