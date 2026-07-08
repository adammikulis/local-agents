extends RefCounted

## CUBED-SPHERE ATMOSPHERE PASS — the emergent vapor→cloud/fog→rain cycle, ported to the sphere grid.
##
## Wires the four cubed-sphere atmosphere kernels into the sphere GPU driver via the shared pass PLUGIN
## CONTRACT (setup + dispatch). Each kernel is the sphere port of a proven box kernel; the buffer
## chaining, per-field transport gains, orographic gain, and dewpoint/boil/rain constants are copied
## VERBATIM from the verified box driver (`MaterialGPU3D.step()` + `MaterialGPU3DPush.gd`) so behaviour
## matches. The ONLY structural differences from the box are (a) the sphere kernels take a NEIGHBOUR
## table SSBO at binding 15 instead of index arithmetic, and (b) their push constant leads with
## `cell_count` (no dim_x/y/z) — see the per-kernel push builders below.
##
## PLUGIN CONTRACT
##   setup(rd, bufs, cc)  — load 4 shaders/pipelines, allocate the two internal scratch buffers
##                          (per-cell rain + boil, shared condense→rain), and build 2 uniform sets per
##                          kernel (one per parity p; PAIR channel bindings use live=[p]/back=[1-p]).
##   dispatch(rd, cl, parity, ctx, cc, groups) — record the four stages into the driver's compute list
##                          `cl` (driver owns begin/end/submit). ctx scalars: ctx["wind"] (Vector2
##                          prevailing, X→a-axis / Y(z)→b-axis for the orographic test), ctx["dt"]
##                          (step_dt, default 0.1), ctx["cell_size"] (default 5.0 — the field cell size,
##                          folded with dt+wind_gain into the transport `wdt`). ctx["precip"] is NOT
##                          consumed here (it feeds the scent/fungus passes, not condensation).
##
## bufs channels used (PAIR → [rid_a, rid_b] ping-pong; SINGLE → rid):
##   PAIR:  temp water vapor cloud fog        SINGLE: solid static vel_x vel_z nbr
##
## BUFFER CHAINING (mirrors the box; everything the pass touches ends in the `back` = [1-parity] slot so
## the driver's single end-of-frame parity flip promotes it to live). temp/water are read from their
## `back` slot because the heat + water passes have already written this frame's post-step values there;
## condense/rain then modify water[back] IN PLACE (rain deposit + boil drain):
##   1) EVAP:      vapor[live] --(+evap over warm wet surfaces)--> vapor[back]
##   2) TRANSPORT: vapor[back] --(diffuse/rise/wind)--> vapor[live]  (reuses the now-free live as scratch);
##                 cloud[live] --> cloud[back];  fog[live] --> fog[back]
##   3) CONDENSE:  vapor[live] (post-transport) --> vapor[back]; cloud[back]/fog[back] updated in place;
##                 per-cell rain + boil written to the internal scratch buffers
##   4) RAIN:      gather rain scratch → water[back] (fall to ground); drain boil scratch from water[back]
##
## DISPATCH ORDER is EVAP → TRANSPORT(×3) → CONDENSE → RAIN. (The contract's shorthand listed transport
## first, but the buffer chain forces evap first: transport-vapor consumes evap's output sitting in
## vapor[back]. This is exactly the proven box order in MaterialGPU3D.step().)

const TRANSPORT_PATH: String = "res://addons/local_agents/scenes/simulation/voxel/material/kernels3d/atmos_transport_sphere3d.glsl"
const EVAP_PATH: String = "res://addons/local_agents/scenes/simulation/voxel/material/kernels3d/atmos_evap_sphere3d.glsl"
const CONDENSE_PATH: String = "res://addons/local_agents/scenes/simulation/voxel/material/kernels3d/atmos_condense_sphere3d.glsl"
const RAIN_PATH: String = "res://addons/local_agents/scenes/simulation/voxel/material/kernels3d/atmos_rain_sphere3d.glsl"

# Per-field transport gains — copied VERBATIM from MaterialGPU3D / MaterialAtmosphere3D so the sphere
# advection matches the box. Fog does not rise (rise_frac 0) and drifts at half wind (ground drag).
const VAPOR_DIFFUSE: float = 0.14
const CLOUD_DIFFUSE: float = 0.06
const FOG_DIFFUSE: float = 0.03
const VAPOR_RISE: float = 0.10
const CLOUD_RISE: float = 0.04
const FOG_RISE: float = 0.0
const VAPOR_WIND_GAIN: float = 1.0
const CLOUD_WIND_GAIN: float = 1.0
const FOG_WIND_GAIN: float = 0.5
const ORO_CONDENSE_GAIN: float = 1.3       # windward-slope condensation boost (drives the condense oro test)

# Default field cell size (MaterialField3D._cell_size = 5.0) + step dt (STEP_DT = 1/10). Used only to
# fold each field's `wdt = wind_gain * dt / cell_size` when ctx omits them.
const DEFAULT_CELL_SIZE: float = 5.0
const DEFAULT_DT: float = 0.1

var _cc: int = 0

var _transport_shader: RID = RID()
var _evap_shader: RID = RID()
var _condense_shader: RID = RID()
var _rain_shader: RID = RID()

var _transport_pipe: RID = RID()
var _evap_pipe: RID = RID()
var _condense_pipe: RID = RID()
var _rain_pipe: RID = RID()

# Internal per-cell scratch (cell_count floats each). condense WRITES both (fully, every cell), rain
# READS both — never surfaced to the driver, so the pass owns them.
var _rain_buf: RID = RID()
var _boil_buf: RID = RID()

# One uniform set per kernel per parity p (index 0/1). Picked by `parity` at dispatch.
var _evap_set: Array = [RID(), RID()]
var _transport_vapor_set: Array = [RID(), RID()]
var _transport_cloud_set: Array = [RID(), RID()]
var _transport_fog_set: Array = [RID(), RID()]
var _condense_set: Array = [RID(), RID()]
var _rain_set: Array = [RID(), RID()]


func setup(rd: RenderingDevice, bufs: Dictionary, cc: int) -> void:
	_cc = cc

	var transport_sf: RDShaderFile = load(TRANSPORT_PATH)
	_transport_shader = rd.shader_create_from_spirv(transport_sf.get_spirv())
	_transport_pipe = rd.compute_pipeline_create(_transport_shader)
	var evap_sf: RDShaderFile = load(EVAP_PATH)
	_evap_shader = rd.shader_create_from_spirv(evap_sf.get_spirv())
	_evap_pipe = rd.compute_pipeline_create(_evap_shader)
	var condense_sf: RDShaderFile = load(CONDENSE_PATH)
	_condense_shader = rd.shader_create_from_spirv(condense_sf.get_spirv())
	_condense_pipe = rd.compute_pipeline_create(_condense_shader)
	var rain_sf: RDShaderFile = load(RAIN_PATH)
	_rain_shader = rd.shader_create_from_spirv(rain_sf.get_spirv())
	_rain_pipe = rd.compute_pipeline_create(_rain_shader)

	var zeros: PackedByteArray = _zeros(cc)
	_rain_buf = rd.storage_buffer_create(zeros.size(), zeros)
	_boil_buf = rd.storage_buffer_create(zeros.size(), _zeros(cc))

	var vapor: Array = bufs["vapor"]
	var cloud: Array = bufs["cloud"]
	var fog: Array = bufs["fog"]
	var temp: Array = bufs["temp"]
	var water: Array = bufs["water"]
	var solid: RID = bufs["solid"]
	var stat: RID = bufs["static"]
	var vel_x: RID = bufs["vel_x"]
	var vel_z: RID = bufs["vel_z"]
	var nbr: RID = bufs["nbr"]

	for p in 2:
		var back: int = 1 - p

		# EVAP — atmos_evap_sphere3d.glsl: 0=vapor in(live), 1=temp(back, post-heat), 2=water(back,
		# post-flow), 3=solid, 4=static, 5=vapor out(back), 15=nbr.
		_evap_set[p] = _mkset(rd, _evap_shader, [
			[0, vapor[p]], [1, temp[back]], [2, water[back]], [3, solid],
			[4, stat], [5, vapor[back]], [15, nbr]])

		# TRANSPORT — atmos_transport_sphere3d.glsl: 0=q in, 1=solid, 2=q out, 3=vel_x, 4=vel_z, 15=nbr.
		# VAPOR reads its post-evap back and writes the now-free live as scratch; CLOUD/FOG read live
		# and write back.
		_transport_vapor_set[p] = _mkset(rd, _transport_shader, [
			[0, vapor[back]], [1, solid], [2, vapor[p]], [3, vel_x], [4, vel_z], [15, nbr]])
		_transport_cloud_set[p] = _mkset(rd, _transport_shader, [
			[0, cloud[p]], [1, solid], [2, cloud[back]], [3, vel_x], [4, vel_z], [15, nbr]])
		_transport_fog_set[p] = _mkset(rd, _transport_shader, [
			[0, fog[p]], [1, solid], [2, fog[back]], [3, vel_x], [4, vel_z], [15, nbr]])

		# CONDENSE — atmos_condense_sphere3d.glsl: 0=vapor in(live, post-transport), 1=cloud(back, in
		# place), 2=fog(back, in place), 3=temp(back), 4=water(back), 5=solid, 6=static, 7=vapor
		# out(back), 8=rain scratch, 9=boil scratch, 15=nbr.
		_condense_set[p] = _mkset(rd, _condense_shader, [
			[0, vapor[p]], [1, cloud[back]], [2, fog[back]], [3, temp[back]],
			[4, water[back]], [5, solid], [6, stat], [7, vapor[back]],
			[8, _rain_buf], [9, _boil_buf], [15, nbr]])

		# RAIN — atmos_rain_sphere3d.glsl: 0=rain scratch, 1=solid, 2=water(back, in place += rain −
		# boil), 3=boil scratch, 15=nbr.
		_rain_set[p] = _mkset(rd, _rain_shader, [
			[0, _rain_buf], [1, solid], [2, water[back]], [3, _boil_buf], [15, nbr]])


func dispatch(rd: RenderingDevice, cl: int, parity: int, ctx: Dictionary, cc: int, groups: int) -> void:
	var wind: Vector2 = ctx.get("wind", Vector2.ZERO)
	var dt: float = float(ctx.get("dt", DEFAULT_DT))
	var cell_size: float = float(ctx.get("cell_size", DEFAULT_CELL_SIZE))

	# STAGE 1 — EVAPORATION: vapor[live] + evap over warm wet surfaces -> vapor[back].
	rd.compute_list_bind_compute_pipeline(cl, _evap_pipe)
	rd.compute_list_bind_uniform_set(cl, _evap_set[parity], 0)
	rd.compute_list_set_push_constant(cl, _pc_plain(cc), 16)
	rd.compute_list_dispatch(cl, groups, 1, 1)
	rd.compute_list_add_barrier(cl)          # post-evap vapor[back] visible to its transport read

	# STAGE 2 — TRANSPORT (vapor / cloud / fog). Each reads a snapshot and writes a disjoint buffer, so
	# the three are mutually independent → no barrier needed BETWEEN them.
	rd.compute_list_bind_compute_pipeline(cl, _transport_pipe)
	rd.compute_list_bind_uniform_set(cl, _transport_vapor_set[parity], 0)
	rd.compute_list_set_push_constant(cl, _pc_transport(cc, VAPOR_DIFFUSE, VAPOR_RISE, _wdt(VAPOR_WIND_GAIN, dt, cell_size)), 16)
	rd.compute_list_dispatch(cl, groups, 1, 1)
	rd.compute_list_bind_uniform_set(cl, _transport_cloud_set[parity], 0)
	rd.compute_list_set_push_constant(cl, _pc_transport(cc, CLOUD_DIFFUSE, CLOUD_RISE, _wdt(CLOUD_WIND_GAIN, dt, cell_size)), 16)
	rd.compute_list_dispatch(cl, groups, 1, 1)
	rd.compute_list_bind_uniform_set(cl, _transport_fog_set[parity], 0)
	rd.compute_list_set_push_constant(cl, _pc_transport(cc, FOG_DIFFUSE, FOG_RISE, _wdt(FOG_WIND_GAIN, dt, cell_size)), 16)
	rd.compute_list_dispatch(cl, groups, 1, 1)
	rd.compute_list_add_barrier(cl)          # post-transport vapor/cloud/fog visible to condensation

	# STAGE 3 — CONDENSATION + rain/boil accounting. Per void cell: dewpoint condense/re-evap/decay/boil,
	# rain written to the scratch. vapor[live] -> vapor[back]; cloud/fog[back] updated in place.
	rd.compute_list_bind_compute_pipeline(cl, _condense_pipe)
	rd.compute_list_bind_uniform_set(cl, _condense_set[parity], 0)
	rd.compute_list_set_push_constant(cl, _pc_condense(cc, wind.x, wind.y, ORO_CONDENSE_GAIN), 16)
	rd.compute_list_dispatch(cl, groups, 1, 1)
	rd.compute_list_add_barrier(cl)          # rain + boil scratch visible to the rain gather

	# STAGE 4 — RAIN GATHER: route each cell's rain toward the ground and drain boiled water; water[back]
	# += rain − boil, in place.
	rd.compute_list_bind_compute_pipeline(cl, _rain_pipe)
	rd.compute_list_bind_uniform_set(cl, _rain_set[parity], 0)
	rd.compute_list_set_push_constant(cl, _pc_plain(cc), 16)
	rd.compute_list_dispatch(cl, groups, 1, 1)
	rd.compute_list_add_barrier(cl)          # water[back] settle visible to downstream passes


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


# Fold wind_gain * step_dt / cell_size into the per-step advection scale the transport kernel expects
# (per-cell ax = clamp(|vel| * wdt, 0, 0.5)). Matches MaterialGPU3DPush.transport_pc().
func _wdt(wind_gain: float, dt: float, cell_size: float) -> float:
	var cs: float = cell_size if cell_size > 0.0 else 1.0
	return wind_gain * dt / cs


# evap + rain Params: {uint cell_count, uint pad0, uint pad1, uint pad2} (16 bytes).
func _pc_plain(cc: int) -> PackedByteArray:
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(16)
	pc.encode_u32(0, cc)
	pc.encode_u32(4, 0)
	pc.encode_u32(8, 0)
	pc.encode_u32(12, 0)
	return pc


# transport Params: {uint cell_count, float diffuse_frac, float rise_frac, float wdt} (16 bytes).
func _pc_transport(cc: int, diffuse_frac: float, rise_frac: float, wdt: float) -> PackedByteArray:
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(16)
	pc.encode_u32(0, cc)
	pc.encode_float(4, diffuse_frac)
	pc.encode_float(8, rise_frac)
	pc.encode_float(12, wdt)
	return pc


# condense Params: {uint cell_count, float wind_x, float wind_z, float oro_gain} (16 bytes).
func _pc_condense(cc: int, wind_x: float, wind_z: float, oro_gain: float) -> PackedByteArray:
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(16)
	pc.encode_u32(0, cc)
	pc.encode_float(4, wind_x)
	pc.encode_float(8, wind_z)
	pc.encode_float(12, oro_gain)
	return pc


func _zeros(n: int) -> PackedByteArray:
	var a: PackedFloat32Array = PackedFloat32Array()
	a.resize(n)
	return a.to_byte_array()
