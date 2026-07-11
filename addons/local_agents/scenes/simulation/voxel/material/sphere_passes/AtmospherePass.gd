extends RefCounted

## CUBED-SPHERE ATMOSPHERE PASS — the emergent water cycle on ONE conserved `moisture` channel.
##
## Phase 2a collapsed the three separate atmospheric water channels vapor/cloud/fog into a SINGLE conserved
## `moisture` (total water suspended in a cell's air). cloud/fog/vapor are no longer stored — they are
## DERIVED at read time from `moisture` vs `sat(T)` (see MaterialField3D._condensed_at). So condensation,
## re-evaporation and cloud-decay disappear as discrete steps; the only real mass transfers left are:
##   EVAP(+BOIL): water -> moisture (conserving; debits DYNAMIC water, static sea is an infinite reservoir)
##   PRECIP:      the heavy condensed part of moisture sheds rain into a scratch (moisture -= rain)
##   RAIN gather: routes that rain down the radial column into the ground water
## plus one conservative TRANSPORT of moisture (diffuse / buoyant rise / wind).
##
## PLUGIN CONTRACT
##   setup(rd, bufs, cc)  — load 4 shaders/pipelines, allocate the rain scratch (+ a zeroed boil scratch the
##                          unchanged rain gather still reads), and build 2 uniform sets per kernel (one per
##                          parity p; PAIR channel bindings use live=[p]/back=[1-p]).
##   dispatch(rd, cl, parity, ctx, cc, groups) — record the four stages into the driver's compute list.
##                          ctx: ctx["wind"] (Vector2 prevailing), ctx["dt"] (default 0.1),
##                          ctx["cell_size"] (default 5.0, folded with dt+wind_gain into the transport wdt).
##
## bufs channels used (PAIR → [rid_a, rid_b] ping-pong; SINGLE → rid):
##   PAIR:  temp water moisture        SINGLE: solid static vel_x vel_z nbr
##
## BUFFER CHAINING (ping-pong; everything the pass touches for `moisture` ends in the `back` = [1-parity]
## slot so the driver's end-of-frame parity flip promotes it to live). temp/water are read from `back`
## (Thermal + water passes already wrote this frame's post-step values there); evap DEBITS water[back] in
## place and the rain gather DEPOSITS into water[back] in place:
##   1) EVAP:      moisture[live] --(+evap/+boil; debit water[back])--> moisture[back]
##   2) TRANSPORT: moisture[back]  --(diffuse/rise/wind)--> moisture[live]  (reuses now-free live as scratch)
##   3) PRECIP:    moisture[live] (post-transport) --(-rain)--> moisture[back]; rain -> scratch
##   4) RAIN:      gather rain scratch --> water[back] (fall down the column)
## moisture therefore ENDS in back[1-parity]; the parity flip makes it live next step.
##
## VERTICAL RISE = REAL WIND (Phase 2a §"Vertical rise folds into buoyant wind", now landed): the transport's
## old constant `rise_frac` buoyant term is REPLACED by upwind advection along the actual radial wind vel_y.
## This is what turns cloud from a uniform thin veil into DISTINCT MASSES: a constant rise lifts humidity at
## the same rate everywhere (so, with diffusion, moisture stays flat), whereas riding vel_y concentrates it
## where warm updrafts converge (cloud banks) and clears it where air subsides (gaps of clear sky).
## Diffusion is also kept WEAK so it can't smear the masses back flat. Still ONE conservative transport pass.

const TRANSPORT_PATH: String = "res://addons/local_agents/scenes/simulation/voxel/material/kernels3d/atmos_transport_sphere3d.glsl"
const EVAP_PATH: String = "res://addons/local_agents/scenes/simulation/voxel/material/kernels3d/atmos_evap_sphere3d.glsl"
const PRECIP_PATH: String = "res://addons/local_agents/scenes/simulation/voxel/material/kernels3d/atmos_precip_sphere3d.glsl"
const RAIN_PATH: String = "res://addons/local_agents/scenes/simulation/voxel/material/kernels3d/atmos_rain_sphere3d.glsl"

# Single-channel transport gains for `moisture`. To make cloud form DISTINCT MASSES (not a uniform veil),
# moisture must CLUMP: diffusion is kept WEAK (strong diffusion smears the field flat), and the old constant
# buoyant rise is replaced by advection along the REAL radial wind vel_y (MOISTURE_VWIND_GAIN) — warm
# updrafts concentrate humidity into cloud banks where the vertical flow converges, subsidence clears the
# gaps. Horizontal wind (MOISTURE_WIND_GAIN) still drifts the masses with the prevailing flow.
const MOISTURE_DIFFUSE: float = 0.035
const MOISTURE_VWIND_GAIN: float = 4.5
const MOISTURE_WIND_GAIN: float = 1.0

# Default field cell size (MaterialField3D._cell_size = 5.0) + step dt (STEP_DT = 1/10). Used only to fold
# the transport `wdt = wind_gain * dt / cell_size` when ctx omits them.
const DEFAULT_CELL_SIZE: float = 5.0
const DEFAULT_DT: float = 0.1

var _cc: int = 0

var _transport_shader: RID = RID()
var _evap_shader: RID = RID()
var _precip_shader: RID = RID()
var _rain_shader: RID = RID()

var _transport_pipe: RID = RID()
var _evap_pipe: RID = RID()
var _precip_pipe: RID = RID()
var _rain_pipe: RID = RID()

# Internal per-cell scratch (cell_count floats each). PRECIP WRITES the rain scratch (every cell), the rain
# gather READS it. The boil scratch is kept ZEROED only so the UNCHANGED atmos_rain_sphere3d (which still
# binds a boil drain at binding 3) reads all-zeros — boiling now debits water directly in the evap kernel.
var _rain_buf: RID = RID()
var _boil_buf: RID = RID()

# One uniform set per kernel per parity p (index 0/1). Picked by `parity` at dispatch.
var _evap_set: Array = [RID(), RID()]
var _transport_set: Array = [RID(), RID()]
var _precip_set: Array = [RID(), RID()]
var _rain_set: Array = [RID(), RID()]


func setup(rd: RenderingDevice, bufs: Dictionary, cc: int) -> void:
	_cc = cc

	var transport_sf: RDShaderFile = load(TRANSPORT_PATH)
	_transport_shader = rd.shader_create_from_spirv(transport_sf.get_spirv())
	_transport_pipe = rd.compute_pipeline_create(_transport_shader)
	var evap_sf: RDShaderFile = load(EVAP_PATH)
	_evap_shader = rd.shader_create_from_spirv(evap_sf.get_spirv())
	_evap_pipe = rd.compute_pipeline_create(_evap_shader)
	var precip_sf: RDShaderFile = load(PRECIP_PATH)
	_precip_shader = rd.shader_create_from_spirv(precip_sf.get_spirv())
	_precip_pipe = rd.compute_pipeline_create(_precip_shader)
	var rain_sf: RDShaderFile = load(RAIN_PATH)
	_rain_shader = rd.shader_create_from_spirv(rain_sf.get_spirv())
	_rain_pipe = rd.compute_pipeline_create(_rain_shader)

	_rain_buf = rd.storage_buffer_create(_zeros(cc).size(), _zeros(cc))
	_boil_buf = rd.storage_buffer_create(_zeros(cc).size(), _zeros(cc))

	var moisture: Array = bufs["moisture"]
	var temp: Array = bufs["temp"]
	var water: Array = bufs["water"]
	var solid: RID = bufs["solid"]
	var stat: RID = bufs["static"]
	var vel_x: RID = bufs["vel_x"]
	var vel_y: RID = bufs["vel_y"]
	var vel_z: RID = bufs["vel_z"]
	var nbr: RID = bufs["nbr"]

	for p in 2:
		var back: int = 1 - p

		# EVAP — atmos_evap_sphere3d.glsl: 0=moisture in(live), 1=temp(back), 2=water(back, debited in
		# place), 3=solid, 4=static, 5=moisture out(back), 15=nbr.
		_evap_set[p] = _mkset(rd, _evap_shader, [
			[0, moisture[p]], [1, temp[back]], [2, water[back]], [3, solid],
			[4, stat], [5, moisture[back]], [15, nbr]])

		# TRANSPORT — atmos_transport_sphere3d.glsl: 0=q in(post-evap back), 1=solid, 2=q out(live scratch),
		# 3=vel_x, 4=vel_z, 5=vel_y (radial-up wind), 15=nbr.
		_transport_set[p] = _mkset(rd, _transport_shader, [
			[0, moisture[back]], [1, solid], [2, moisture[p]], [3, vel_x], [4, vel_z], [5, vel_y], [15, nbr]])

		# PRECIP — atmos_precip_sphere3d.glsl: 0=moisture in(live, post-transport), 1=temp(back), 2=solid,
		# 3=moisture out(back), 4=rain scratch.
		_precip_set[p] = _mkset(rd, _precip_shader, [
			[0, moisture[p]], [1, temp[back]], [2, solid], [3, moisture[back]], [4, _rain_buf]])

		# RAIN — atmos_rain_sphere3d.glsl: 0=rain scratch, 1=solid, 2=water(back, in place += rain − boil),
		# 3=boil scratch (all zeros now), 4=STATIC (rain over the sea vanishes into the infinite reservoir, not
		# parked in undrained static-cell water — the fix for the unbounded h2o climb), 15=nbr.
		_rain_set[p] = _mkset(rd, _rain_shader, [
			[0, _rain_buf], [1, solid], [2, water[back]], [3, _boil_buf], [4, stat], [15, nbr]])


func dispatch(rd: RenderingDevice, cl: int, parity: int, ctx: Dictionary, cc: int, groups: int) -> void:
	var dt: float = float(ctx.get("dt", DEFAULT_DT))
	var cell_size: float = float(ctx.get("cell_size", DEFAULT_CELL_SIZE))

	# STAGE 1 — EVAPORATION + BOILING: moisture[live] + evap/boil -> moisture[back]; DYNAMIC water[back]
	# debited in place (conserving).
	rd.compute_list_bind_compute_pipeline(cl, _evap_pipe)
	rd.compute_list_bind_uniform_set(cl, _evap_set[parity], 0)
	rd.compute_list_set_push_constant(cl, _pc_plain(cc), 16)
	rd.compute_list_dispatch(cl, groups, 1, 1)
	rd.compute_list_add_barrier(cl)          # post-evap moisture[back] visible to transport

	# STAGE 2 — TRANSPORT: moisture[back] --(weak diffuse / vel_y updraft advection / horizontal wind)-->
	# moisture[live] (one conservative pass). vel_y advection is what CLUMPS the field into cloud masses.
	rd.compute_list_bind_compute_pipeline(cl, _transport_pipe)
	rd.compute_list_bind_uniform_set(cl, _transport_set[parity], 0)
	rd.compute_list_set_push_constant(cl, _pc_transport(cc, MOISTURE_DIFFUSE, _wdt(MOISTURE_VWIND_GAIN, dt, cell_size), _wdt(MOISTURE_WIND_GAIN, dt, cell_size)), 16)
	rd.compute_list_dispatch(cl, groups, 1, 1)
	rd.compute_list_add_barrier(cl)          # post-transport moisture[live] visible to precip

	# STAGE 3 — PRECIPITATION: derive condensed = max(0, moisture − sat(T)); shed rain to the scratch;
	# moisture[live] -> moisture[back].
	rd.compute_list_bind_compute_pipeline(cl, _precip_pipe)
	rd.compute_list_bind_uniform_set(cl, _precip_set[parity], 0)
	rd.compute_list_set_push_constant(cl, _pc_plain(cc), 16)
	rd.compute_list_dispatch(cl, groups, 1, 1)
	rd.compute_list_add_barrier(cl)          # rain scratch visible to the rain gather

	# STAGE 4 — RAIN GATHER: route each cell's rain down the radial column; water[back] += rain, in place.
	rd.compute_list_bind_compute_pipeline(cl, _rain_pipe)
	rd.compute_list_bind_uniform_set(cl, _rain_set[parity], 0)
	rd.compute_list_set_push_constant(cl, _pc_plain(cc), 16)
	rd.compute_list_dispatch(cl, groups, 1, 1)
	rd.compute_list_add_barrier(cl)          # water[back] settle visible to downstream passes


func dispose(rd: RenderingDevice) -> void:
	if rd == null:
		return
	# Uniform sets first (dependent-first), then pipelines/shaders, then the private scratch buffers.
	for s: Array in [_evap_set, _transport_set, _precip_set, _rain_set]:
		for r in s:
			if r is RID and r.is_valid():
				rd.free_rid(r)
	_evap_set = [RID(), RID()]
	_transport_set = [RID(), RID()]
	_precip_set = [RID(), RID()]
	_rain_set = [RID(), RID()]
	for r in [_transport_pipe, _evap_pipe, _precip_pipe, _rain_pipe,
			_transport_shader, _evap_shader, _precip_shader, _rain_shader,
			_rain_buf, _boil_buf]:
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


# Fold wind_gain * step_dt / cell_size into the per-step advection scale the transport kernel expects
# (per-cell ax = clamp(|vel| * wdt, 0, 0.5)).
func _wdt(wind_gain: float, dt: float, cell_size: float) -> float:
	var cs: float = cell_size if cell_size > 0.0 else 1.0
	return wind_gain * dt / cs


# evap / precip / rain Params: {uint cell_count, uint pad0, uint pad1, uint pad2} (16 bytes).
func _pc_plain(cc: int) -> PackedByteArray:
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(16)
	pc.encode_u32(0, cc)
	pc.encode_u32(4, 0)
	pc.encode_u32(8, 0)
	pc.encode_u32(12, 0)
	return pc


# transport Params: {uint cell_count, float diffuse_frac, float wdt_y, float wdt} (16 bytes).
func _pc_transport(cc: int, diffuse_frac: float, wdt_y: float, wdt: float) -> PackedByteArray:
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(16)
	pc.encode_u32(0, cc)
	pc.encode_float(4, diffuse_frac)
	pc.encode_float(8, wdt_y)
	pc.encode_float(12, wdt)
	return pc


func _zeros(n: int) -> PackedByteArray:
	var a: PackedFloat32Array = PackedFloat32Array()
	a.resize(n)
	return a.to_byte_array()
