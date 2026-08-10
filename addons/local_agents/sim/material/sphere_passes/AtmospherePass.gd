extends RefCounted


const TRANSPORT_PATH: String = "res://addons/local_agents/sim/material/kernels3d/tracer_transport_sphere3d.glsl"
const PRECIP_PATH: String = "res://addons/local_agents/sim/material/kernels3d/atmos_precip_sphere3d.glsl"
const RAIN_PATH: String = "res://addons/local_agents/sim/material/kernels3d/atmos_rain_sphere3d.glsl"

# --- PRECIPITATION IS A MICROPHYSICAL PROCESS, NOT A CEILING -----------------------------------------------
const AUTOCONVERSION_RATE_PER_S: float = 1.0e-3    # Kessler (1969) k_auto
const CLOUD_WATER_CRIT_KG_KG: float = 0.5e-3       # Kessler (1969) q_crit, cloud-water mixing ratio
const AIR_DENSITY_KG_M3: float = 1.225             # ISA sea level, 15 °C


## The autoconversion threshold in the field's own unit (fraction of a cell full of liquid water).
static func rain_threshold() -> float:
	return CLOUD_WATER_CRIT_KG_KG * AIR_DENSITY_KG_M3 / LAPhysical.WATER_DENSITY_KG_M3


## Fraction of the supercritical cloud water shed as rain in ONE field step. Kessler's rate is per SECOND, and
## a field step stands for LAMaterialFieldSphereStep3D.real_seconds_per_step() of them (43.2 s at the shipped
## 200 s day), so the conversion is the substrate's own clock and not a per-step number anybody chose.
static func rain_rate_per_step() -> float:
	return clampf(AUTOCONVERSION_RATE_PER_S * LAMaterialFieldSphereStep3D.real_seconds_per_step(), 0.0, 1.0)

const MOISTURE_DIFFUSE: float = 0.035
# Water vapour, 18.015 g/mol against dry air 28.968: contrast -0.37812, i.e. it RISES. Falls out of the same
# settling expression every other tracer uses, with no separate updraft gain.
#  advection differently in the vertical and the horizontal.)*
const MOISTURE_CONTRAST: float = -0.37812
const SETTLE_V_PER_CONTRAST: float = 0.05

# Default field cell size (MaterialField3D._cell_size = 5.0) + step dt (STEP_DT = 1/10). Used only to fold
# the transport `wdt = wind_gain * dt / cell_size` when ctx omits them.
const DEFAULT_CELL_SIZE: float = 5.0
const DEFAULT_DT: float = 0.1

var _cc: int = 0

var _transport_shader: RID = RID()
var _precip_shader: RID = RID()
var _rain_shader: RID = RID()

var _transport_pipe: RID = RID()
var _precip_pipe: RID = RID()
var _rain_pipe: RID = RID()

var _rain_buf: RID = RID()
# Private moisture scratch — the transport's output and the precip's input. See the chaining note in the
# header: with evaporation dissolved into the reaction engine there are only two moisture-writing stages left,
# and a two-link ping-pong cannot both start in live and end in back.
var _moist_buf: RID = RID()

# One uniform set per kernel per parity p (index 0/1). Picked by `parity` at dispatch.
var _transport_set: Array = [RID(), RID()]
var _precip_set: Array = [RID(), RID()]
var _rain_set: Array = [RID(), RID()]


func setup(rd: RenderingDevice, bufs: Dictionary, cc: int) -> void:
	_cc = cc

	var transport_sf: RDShaderFile = load(TRANSPORT_PATH)
	_transport_shader = rd.shader_create_from_spirv(transport_sf.get_spirv())
	_transport_pipe = rd.compute_pipeline_create(_transport_shader)
	var precip_sf: RDShaderFile = load(PRECIP_PATH)
	_precip_shader = rd.shader_create_from_spirv(precip_sf.get_spirv())
	_precip_pipe = rd.compute_pipeline_create(_precip_shader)
	var rain_sf: RDShaderFile = load(RAIN_PATH)
	_rain_shader = rd.shader_create_from_spirv(rain_sf.get_spirv())
	_rain_pipe = rd.compute_pipeline_create(_rain_shader)

	_rain_buf = rd.storage_buffer_create(_zeros(cc).size(), _zeros(cc))
	_moist_buf = rd.storage_buffer_create(_zeros(cc).size(), _zeros(cc))

	var moisture: Array = bufs["moisture"]
	var temp: Array = bufs["temp"]
	var water: Array = bufs["water"]
	var solid: RID = bufs["solid"]
	var stat: RID = bufs["static"]
	var vel_x: RID = bufs["vel_x"]
	var vel_y: RID = bufs["vel_y"]
	var vel_z: RID = bufs["vel_z"]
	var nbr: RID = bufs["nbr"]
	# Per-column tangent-frame table — the horizontal wind is stored in each cell's own frame, so transport
	# reads link directions from here instead of assuming a slot is an axis (see wind_step_sphere3d).
	var ltan: RID = bufs["link_tan"]

	for p in 2:
		var back: int = 1 - p

		# tracer_transport: 0=in(live), 1=out(private scratch), 2=deposit(unused, bound to the scratch),
		_transport_set[p] = _mkset(rd, _transport_shader, [
			[0, moisture[p]], [1, _moist_buf], [2, _moist_buf], [3, solid],
			[4, vel_x], [5, vel_y], [6, vel_z], [15, nbr], [16, ltan]])

		# PRECIP — atmos_precip_sphere3d.glsl: 0=moisture in(post-transport scratch), 1=temp(back), 2=solid,
		# 3=moisture out(back), 4=rain scratch.
		_precip_set[p] = _mkset(rd, _precip_shader, [
			[0, _moist_buf], [1, temp[back]], [2, solid], [3, moisture[back]], [4, _rain_buf]])

		# RAIN — atmos_rain_sphere3d.glsl: 0=rain scratch, 1=solid, 2=water(back, in place += rain),
		# 4=STATIC (rain over the sea vanishes into the infinite reservoir, not
		# parked in undrained static-cell water — the fix for the unbounded h2o climb), 15=nbr.
		_rain_set[p] = _mkset(rd, _rain_shader, [
			[0, _rain_buf], [1, solid], [2, water[back]], [4, stat], [15, nbr]])


func dispatch(rd: RenderingDevice, cl: int, parity: int, ctx: Dictionary, cc: int, groups: int) -> void:
	var dt: float = float(ctx.get("dt", DEFAULT_DT))
	var cell_size: float = float(ctx.get("cell_size", DEFAULT_CELL_SIZE))

	# STAGE 1 — TRANSPORT: moisture[live] --(weak diffuse / vel_y updraft advection / horizontal wind)-->
	# the private scratch (one conservative pass). vel_y advection is what CLUMPS the field into cloud masses.
	rd.compute_list_bind_compute_pipeline(cl, _transport_pipe)
	rd.compute_list_bind_uniform_set(cl, _transport_set[parity], 0)
	rd.compute_list_set_push_constant(cl, _pc_transport(cc, maxi(int(ctx.get("depth", 1)), 1),
			LAMaterialFieldSphereStep3D.real_seconds_per_step() / (cell_size * LAPhysical.METRES_PER_MODEL_UNIT),
			SETTLE_V_PER_CONTRAST * MOISTURE_CONTRAST, MOISTURE_DIFFUSE), 32)
	rd.compute_list_dispatch(cl, groups, 1, 1)
	rd.compute_list_add_barrier(cl)          # post-transport scratch visible to precip

	# STAGE 2 — PRECIPITATION: derive condensed = max(0, moisture − sat(T)); autoconvert the part over the
	# critical cloud-water content to rain in the scratch; scratch -> moisture[back].
	rd.compute_list_bind_compute_pipeline(cl, _precip_pipe)
	rd.compute_list_bind_uniform_set(cl, _precip_set[parity], 0)
	rd.compute_list_set_push_constant(cl, _pc_precip(cc), 16)
	rd.compute_list_dispatch(cl, groups, 1, 1)
	rd.compute_list_add_barrier(cl)          # rain scratch visible to the rain gather

	# STAGE 3 — RAIN GATHER: route each cell's rain down the radial column; water[back] += rain, in place.
	rd.compute_list_bind_compute_pipeline(cl, _rain_pipe)
	rd.compute_list_bind_uniform_set(cl, _rain_set[parity], 0)
	rd.compute_list_set_push_constant(cl, _pc_plain(cc), 16)
	rd.compute_list_dispatch(cl, groups, 1, 1)
	rd.compute_list_add_barrier(cl)          # water[back] settle visible to downstream passes


func dispose(rd: RenderingDevice) -> void:
	if rd == null:
		return
	# Uniform sets first (dependent-first), then pipelines/shaders, then the private scratch buffers.
	for s: Array in [_transport_set, _precip_set, _rain_set]:
		for r in s:
			if r is RID and r.is_valid():
				rd.free_rid(r)
	_transport_set = [RID(), RID()]
	_precip_set = [RID(), RID()]
	_rain_set = [RID(), RID()]
	for r in [_transport_pipe, _precip_pipe, _rain_pipe,
			_transport_shader, _precip_shader, _rain_shader,
			_rain_buf, _moist_buf]:
		if r is RID and r.is_valid():
			rd.free_rid(r)


# --- helpers ------------------------------------------------------------------

# Uniform-set builder: binds is an Array of [binding:int, buffer:RID] pairs (all STORAGE_BUFFER).
func _mkset(rd: RenderingDevice, shader: RID, binds: Array) -> RID:
	var uniforms: Array = []
	for b in binds:
		uniforms.append(_u(int(b[0]), b[1]))
	return rd.uniform_set_create(uniforms, shader, 0)


func _u(binding: int, buf: RID) -> RDUniform:
	var u: RDUniform = RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u.binding = binding
	u.add_id(buf)
	return u




# evap / precip / rain Params: {uint cell_count, uint pad0, uint pad1, uint pad2} (16 bytes).
func _pc_plain(cc: int) -> PackedByteArray:
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(16)
	pc.encode_u32(0, cc)
	pc.encode_u32(4, 0)
	pc.encode_u32(8, 0)
	pc.encode_u32(12, 0)
	return pc


# PRECIP push constant: {uint cell_count, float rain_threshold, float rain_rate, uint pad} (16 bytes). Both
# floats are DERIVED above (Kessler autoconversion against the substrate's own clock and the real air/water
# densities) rather than declared in the kernel, so there is exactly one copy of each and nothing to drift.
func _pc_precip(cc: int) -> PackedByteArray:
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(16)
	pc.encode_u32(0, cc)
	pc.encode_float(4, rain_threshold())
	pc.encode_float(8, rain_rate_per_step())
	pc.encode_u32(12, 0)
	return pc


# transport Params: {uint cell_count, float diffuse_frac, float wdt_y, float wdt, uint depth, 3x pad} (32 bytes).
# `depth` turns a cell index into its radial COLUMN, which is how the per-column link-direction table is indexed.
# tracer_transport push: { cell_count, depth, k, settle_v, diffuse, deposit, offset, decay }.
func _pc_transport(cc: int, depth: int, k: float, settle_v: float, diffuse: float) -> PackedByteArray:
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(32)
	pc.encode_u32(0, cc)
	pc.encode_u32(4, depth)
	pc.encode_float(8, k)
	pc.encode_float(12, settle_v)
	pc.encode_float(16, diffuse)
	pc.encode_u32(20, 0)
	pc.encode_u32(24, 0)
	pc.encode_float(28, 0.0)
	return pc


func _zeros(n: int) -> PackedByteArray:
	var a: PackedFloat32Array = PackedFloat32Array()
	a.resize(n)
	return a.to_byte_array()
