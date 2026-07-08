class_name LAMaterialSphereGPU3D
extends RefCounted

## Cubed-sphere GPU field driver (Phase B). Drop-in for LAMaterialGPU3D when the field is a planet: same
## 8-method contract (setup/begin_frame/step/end_frame/set_field/set_precip/set_prevailing/set_raining). It
## allocates ALL field channels (ping-pong pairs) + the shared single buffers + the SphereGrid neighbour /
## radial / position SSBOs, exposes them as a `bufs` dict, and runs a list of per-domain PASS MODULES
## (sphere_passes/*.gd) that each wire their kernels via that dict. Passes are authored independently; the
## driver owns buffer allocation, parity, ctx, dispatch ordering, and readback.
##
## MVP coupling model: one parity flip per step; each pass reads the frame's live buffers and writes back
## (per-pass submit, single flip) — intra-step cross-pass coupling is looser than the box driver (perf-over-
## parity). Correctness-first; tighten ordering later if a behaviour needs it.

# Ping-pong (double-buffered) channels — one _a/_b pair each.
const PAIR_CHANNELS: PackedStringArray = [
	"temp", "water", "vapor", "cloud", "fog", "lava", "sediment", "fire", "dust",
	"o2", "co2", "shock", "fungus", "susp", "fert"]
# scent is a 5-plane packed pair (5*cell_count); handled specially.
# Single (non-ping-pong) float buffers.
const SINGLE_CHANNELS: PackedStringArray = [
	"solid", "static", "fuel", "charge", "detritus", "pressure",
	"vel_x", "vel_y", "vel_z", "dust_outscale", "fungus_fert", "surf_vx", "surf_vz", "snow"]

const PASS_SCRIPTS: PackedStringArray = [
	"res://addons/local_agents/scenes/simulation/voxel/material/sphere_passes/ThermalPass.gd",
	"res://addons/local_agents/scenes/simulation/voxel/material/sphere_passes/WaterSlumpLavaPass.gd",
	"res://addons/local_agents/scenes/simulation/voxel/material/sphere_passes/GasWindPass.gd",
	"res://addons/local_agents/scenes/simulation/voxel/material/sphere_passes/AtmospherePass.gd",
	"res://addons/local_agents/scenes/simulation/voxel/material/sphere_passes/FireDustPass.gd",
	"res://addons/local_agents/scenes/simulation/voxel/material/sphere_passes/EcoSurfacePass.gd"]

const SCENT_PLANES: int = 5

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
var _groups: int = 0
var _send_size: int = 0
var _bufs: Dictionary = {}          # key → RID (single) or [rid_a, rid_b] (pair)
var _passes: Array = []
var _ctx: Dictionary = {}


func setup(field) -> void:
	_field = field
	_grid = field.sphere_grid()
	_cc = field._cell_count
	_rd = RenderingServer.create_local_rendering_device()
	if _rd == null:
		push_error("LAMaterialSphereGPU3D: no RenderingDevice")
		return
	_groups = int(ceil(float(_cc) / 64.0))

	for name in PAIR_CHANNELS:
		_bufs[name] = [_new_f(_cc), _new_f(_cc)]
	_bufs["scent"] = [_new_f(_cc * SCENT_PLANES), _new_f(_cc * SCENT_PLANES)]
	for name in SINGLE_CHANNELS:
		_bufs[name] = _new_f(_cc)
	_send_size = _cc * 6 * 4
	_bufs["send"] = _new_f(_cc * 6)
	# Sphere geometry SSBOs: neighbour table (int32, kernel slot order), radial + position (flat float3).
	var nbr_bytes: PackedByteArray = _grid.neighbours_kernel_order().to_byte_array()
	_bufs["nbr"] = _rd.storage_buffer_create(nbr_bytes.size(), nbr_bytes)
	_bufs["radial"] = _make_vec3_flat(func(c: int) -> Vector3: return _grid.cell_radial(c))
	_bufs["pos"] = _make_vec3_flat(func(c: int) -> Vector3: return _grid.cell_world_pos(c))

	# Seed channels from the field's CPU state.
	_seed("temp", field._temp)
	_seed("o2", field._o2)
	_seed_solid()

	# Load + set up the pass modules (skip any that fail to load — WIP-tolerant).
	for path in PASS_SCRIPTS:
		var scr: GDScript = load(path)
		if scr == null:
			push_warning("sphere pass missing: " + path)
			continue
		var p: RefCounted = scr.new()
		if p.has_method("setup"):
			p.setup(_rd, _bufs, _cc)
			_passes.append(p)


func begin_frame(temp: PackedFloat32Array, water: PackedFloat32Array, solar: float = 0.6, wind: Vector2 = Vector2.ZERO) -> void:
	if _rd == null:
		return
	_upload_f(_live("temp"), temp)
	_upload_f(_live("water"), water)
	_seed_solid()
	_ctx["solar"] = solar
	_ctx["wind"] = wind
	_ctx["dt"] = 0.1
	_ctx["cell_size"] = _grid.cell_size
	_ctx["sea_radius"] = _field.sphere_grid().core_radius   # placeholder; overridden by set_sea_radius
	if not _ctx.has("sun_dir"):
		_ctx["sun_dir"] = Vector3(0, 1, 0)

func set_sun_dir(v: Vector3) -> void:
	_ctx["sun_dir"] = v if v.length() > 0.001 else Vector3(0, 1, 0)

func set_sea_radius(r: float) -> void:
	_ctx["sea_radius"] = r

func step() -> void:
	if _rd == null:
		return
	for p in _passes:
		_rd.buffer_clear(_bufs["send"], 0, _send_size)   # clean scratch for any 2-pass CA
		var cl: int = _rd.compute_list_begin()
		p.dispatch(_rd, cl, _parity, _ctx, _cc, _groups)
		_rd.compute_list_end()
		_rd.submit()
		_rd.sync()
	_parity = 1 - _parity

func end_frame(_rv: bool = true, _rc: bool = true, _rf: bool = true, _rr: bool = true, _rl: bool = true, _rs: bool = true) -> Dictionary:
	var out: Dictionary = _empty_result()
	if _rd == null:
		return out
	for k in ["temp", "water", "vapor", "cloud", "fog", "lava", "fire", "o2", "co2", "dust", "shock"]:
		out[k] = _rd.buffer_get_data(_live(k)).to_float32_array()
	return out

func set_field(name: String, arr) -> void:
	if _rd == null or not _bufs.has(name):
		return
	var b = _bufs[name]
	if b is Array:
		_upload_f(b[_parity], arr)
	else:
		_upload_f(b, arr)

func set_precip(v: float) -> void:
	_ctx["precip"] = v

func set_prevailing(v: Vector2) -> void:
	_ctx["wind"] = v

func set_raining(v: bool) -> void:
	_ctx["raining"] = 1 if v else 0


# --- helpers ------------------------------------------------------------------

func _live(name: String) -> RID:
	return _bufs[name][_parity]

func _new_f(n: int) -> RID:
	var z: PackedByteArray = _zeros(n)
	return _rd.storage_buffer_create(z.size(), z)

func _make_vec3_flat(getter: Callable) -> RID:
	var f: PackedFloat32Array = PackedFloat32Array()
	f.resize(_cc * 3)
	for c in _cc:
		var v: Vector3 = getter.call(c)
		f[c * 3 + 0] = v.x
		f[c * 3 + 1] = v.y
		f[c * 3 + 2] = v.z
	var b: PackedByteArray = f.to_byte_array()
	return _rd.storage_buffer_create(b.size(), b)

func _seed(name: String, arr: PackedFloat32Array) -> void:
	if _bufs.has(name) and arr.size() == _cc:
		var b = _bufs[name]
		var bytes: PackedByteArray = arr.to_byte_array()
		_rd.buffer_update(b[0], 0, bytes.size(), bytes)
		_rd.buffer_update(b[1], 0, bytes.size(), bytes)

func _seed_solid() -> void:
	var f: PackedFloat32Array = PackedFloat32Array()
	f.resize(_cc)
	for i in _cc:
		f[i] = 1.0 if _field._solid[i] != 0 else 0.0
	var b: PackedByteArray = f.to_byte_array()
	_rd.buffer_update(_bufs["solid"], 0, b.size(), b)
	for i in _cc:
		f[i] = 1.0 if _field._static[i] != 0 else 0.0
	var b2: PackedByteArray = f.to_byte_array()
	_rd.buffer_update(_bufs["static"], 0, b2.size(), b2)

func _upload_f(buf: RID, arr: PackedFloat32Array) -> void:
	if arr.size() == _cc:
		var b: PackedByteArray = arr.to_byte_array()
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
