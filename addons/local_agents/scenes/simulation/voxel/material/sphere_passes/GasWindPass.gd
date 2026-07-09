extends RefCounted

## Cubed-sphere GAS + WIND + CHARGE compute pass. Wires six GPU-proven cubed-sphere kernels into the
## sphere GPU driver as ONE recordable pass (the driver owns the RenderingDevice, the compute list, and
## begin/sync/submit). This object only: (1) compiles the six shaders + pipelines and builds two uniform
## sets per kernel (one per ping-pong parity) in `setup()`, and (2) records dispatches into a caller-owned
## compute list in `dispatch()`.
##
## Kernels + role (see each .glsl for the verbatim math):
##   wind_pressure_sphere3d  — PASS A: per-cell air pressure from temperature (no neighbours). pressure <= temp.
##   wind_step_sphere3d      — PASS B: per-cell velocity update down the pressure gradient (+buoy/Coriolis/drag).
##   o2_transport_sphere3d   — symmetric O2 diffusion over the neighbour table (advection dropped on the sphere).
##   co2_transport_sphere3d  — CO2 diffusion + wind advection + downward settle over the neighbour table.
##   charge_accum_sphere3d   — per-cell charge separation from updraft x supercooled cloud, in place on charge.
## (The O₂ sky-refill + CO₂ sky-vent that gas_sky_sphere3d did here dissolved into the generic ReactionsPass —
##  they are now two Reaction records, applied one pass later on the same o2/co2 transport-output buffers.)
##
## PLUGIN CONTRACT (bufs dictionary):
##   PAIR channels (ping-pong [rid_live, rid_back]) used here: temp, o2, co2, cloud.
##   SINGLE channels (rid) used here: solid, pressure, vel_x, vel_y, vel_z, charge, nbr.
## For a dispatch at ping-pong parity p: PAIR reads live = pair[p], PAIR transport writes back = pair[1 - p].
## ReactionsPass (one pass later) edits those same o2/co2 back buffers for the sky exchange/vent; charge edits
## the single charge rid here.

const WIND_PRESSURE_PATH: String = "res://addons/local_agents/scenes/simulation/voxel/material/kernels3d/wind_pressure_sphere3d.glsl"
const WIND_STEP_PATH: String = "res://addons/local_agents/scenes/simulation/voxel/material/kernels3d/wind_step_sphere3d.glsl"
const O2_TRANSPORT_PATH: String = "res://addons/local_agents/scenes/simulation/voxel/material/kernels3d/o2_transport_sphere3d.glsl"
const CO2_TRANSPORT_PATH: String = "res://addons/local_agents/scenes/simulation/voxel/material/kernels3d/co2_transport_sphere3d.glsl"
const CHARGE_ACCUM_PATH: String = "res://addons/local_agents/scenes/simulation/voxel/material/kernels3d/charge_accum_sphere3d.glsl"

# --- default constants used when a scalar is not supplied in ctx (NOTE any default picked) -------------------
const DEFAULT_DT: float = 0.1          # box-kernel STEP_DT default when ctx has no "dt"
const DEFAULT_WIND: Vector2 = Vector2.ZERO   # prevailing wind (pvx, pvz) when ctx has no "wind"
const DEFAULT_BUOY: float = 1.0        # buoyancy enabled (1) when ctx has no "buoy"

var _rd: RenderingDevice = null
var _cc: int = 0

# shaders + pipelines
var _wp_shader: RID = RID()
var _wp_pipe: RID = RID()
var _ws_shader: RID = RID()
var _ws_pipe: RID = RID()
var _o2_shader: RID = RID()
var _o2_pipe: RID = RID()
var _co2_shader: RID = RID()
var _co2_pipe: RID = RID()
var _ch_shader: RID = RID()
var _ch_pipe: RID = RID()

# uniform sets, one per ping-pong parity (index 0 and 1)
var _wp_set: Array = [RID(), RID()]
var _ws_set: Array = [RID(), RID()]
var _o2_set: Array = [RID(), RID()]
var _co2_set: Array = [RID(), RID()]
var _ch_set: Array = [RID(), RID()]


func setup(rd: RenderingDevice, bufs: Dictionary, cc: int) -> void:
	_rd = rd
	_cc = cc
	if _rd == null:
		push_error("GasWindPass: null RenderingDevice")
		return

	_wp_shader = _compile(WIND_PRESSURE_PATH)
	_wp_pipe = _rd.compute_pipeline_create(_wp_shader)
	_ws_shader = _compile(WIND_STEP_PATH)
	_ws_pipe = _rd.compute_pipeline_create(_ws_shader)
	_o2_shader = _compile(O2_TRANSPORT_PATH)
	_o2_pipe = _rd.compute_pipeline_create(_o2_shader)
	_co2_shader = _compile(CO2_TRANSPORT_PATH)
	_co2_pipe = _rd.compute_pipeline_create(_co2_shader)
	_ch_shader = _compile(CHARGE_ACCUM_PATH)
	_ch_pipe = _rd.compute_pipeline_create(_ch_shader)

	var temp: Array = bufs["temp"]     # PAIR
	var o2: Array = bufs["o2"]         # PAIR
	var co2: Array = bufs["co2"]       # PAIR
	# Charge separation feeds on supercooled condensate aloft. cloud/fog are no longer stored (Phase 2a
	# collapsed them into `moisture`); the total suspended water is a fine moisture proxy for the updraft ×
	# cloud charge term (behavioural, perf-over-parity).
	var cloud: Array = bufs["moisture"]   # PAIR (was "cloud"; now the unified moisture channel)
	var solid: RID = bufs["solid"]     # SINGLE
	var pressure: RID = bufs["pressure"]
	var vx: RID = bufs["vel_x"]
	var vy: RID = bufs["vel_y"]
	var vz: RID = bufs["vel_z"]
	var charge: RID = bufs["charge"]
	var nbr: RID = bufs["nbr"]

	for p in 2:
		var back: int = 1 - p
		# wind_pressure: 0=TempIn(live), 1=Solid, 2=PressureOut
		_wp_set[p] = _uset(_wp_shader, [[0, temp[p]], [1, solid], [2, pressure]])
		# wind_step: 0=PressureIn, 1=TempIn(live), 2=Solid, 3=VelX, 4=VelY, 5=VelZ, 15=Neigh
		_ws_set[p] = _uset(_ws_shader, [[0, pressure], [1, temp[p]], [2, solid], [3, vx], [4, vy], [5, vz], [15, nbr]])
		# o2_transport: 0=O2In(live), 1=O2Out(back), 2=Solid, 15=Neigh
		_o2_set[p] = _uset(_o2_shader, [[0, o2[p]], [1, o2[back]], [2, solid], [15, nbr]])
		# co2_transport: 0=CO2In(live), 1=CO2Out(back), 2=Solid, 3=VelX, 4=VelY, 5=VelZ, 15=Neigh
		_co2_set[p] = _uset(_co2_shader, [[0, co2[p]], [1, co2[back]], [2, solid], [3, vx], [4, vy], [5, vz], [15, nbr]])
		# charge_accum: 0=Charge(single, in place), 1=TempIn(live), 2=CloudIn(live), 3=VelY, 4=Solid
		_ch_set[p] = _uset(_ch_shader, [[0, charge], [1, temp[p]], [2, cloud[p]], [3, vy], [4, solid]])


func dispatch(rd: RenderingDevice, cl: int, parity: int, ctx: Dictionary, cc: int, groups: int) -> void:
	if _rd == null:
		return
	var p: int = parity
	var dt: float = float(ctx.get("dt", DEFAULT_DT))
	var wind: Vector2 = ctx.get("wind", DEFAULT_WIND)
	var buoy_on: int = 1 if float(ctx.get("buoy", DEFAULT_BUOY)) >= 0.5 else 0

	var pc_cc: PackedByteArray = _pc_cellcount(cc)              # {cell_count, pad, pad, pad}
	var pc_ws: PackedByteArray = _pc_windstep(cc, wind.x, wind.y, dt, buoy_on)
	var pc_ch: PackedByteArray = _pc_charge(cc, dt)

	# 1) wind_pressure (PASS A): temp -> pressure, purely per-cell.
	rd.compute_list_bind_compute_pipeline(cl, _wp_pipe)
	rd.compute_list_bind_uniform_set(cl, _wp_set[p], 0)
	rd.compute_list_set_push_constant(cl, pc_cc, pc_cc.size())
	rd.compute_list_dispatch(cl, groups, 1, 1)
	rd.compute_list_add_barrier(cl)   # wind_step reads the pressure field written above

	# 2) wind_step (PASS B): pressure gradient -> velocity, in place on vel_x/y/z.
	rd.compute_list_bind_compute_pipeline(cl, _ws_pipe)
	rd.compute_list_bind_uniform_set(cl, _ws_set[p], 0)
	rd.compute_list_set_push_constant(cl, pc_ws, pc_ws.size())
	rd.compute_list_dispatch(cl, groups, 1, 1)
	rd.compute_list_add_barrier(cl)   # o2/co2 advection + charge updraft read the fresh velocity

	# 3) o2_transport: o2[p] -> o2[1-p] (diffusion only).
	rd.compute_list_bind_compute_pipeline(cl, _o2_pipe)
	rd.compute_list_bind_uniform_set(cl, _o2_set[p], 0)
	rd.compute_list_set_push_constant(cl, pc_cc, pc_cc.size())
	rd.compute_list_dispatch(cl, groups, 1, 1)

	# 4) co2_transport: co2[p] -> co2[1-p] (diffusion + wind advection + settle). Independent of o2 above.
	# (The sky exchange/vent that used to edit the o2/co2 transport output in place here now runs as Reaction
	#  records in ReactionsPass, one pass later on those same back buffers — see the header note.)
	rd.compute_list_bind_compute_pipeline(cl, _co2_pipe)
	rd.compute_list_bind_uniform_set(cl, _co2_set[p], 0)
	rd.compute_list_set_push_constant(cl, pc_cc, pc_cc.size())
	rd.compute_list_dispatch(cl, groups, 1, 1)

	# 5) charge_accum: per-cell charge separation in place (reads fresh vel_y + live cloud/temp). Touches only
	# the charge buffer, so it does NOT conflict with the o2/co2 transport above — no barrier needed between them.
	rd.compute_list_bind_compute_pipeline(cl, _ch_pipe)
	rd.compute_list_bind_uniform_set(cl, _ch_set[p], 0)
	rd.compute_list_set_push_constant(cl, pc_ch, pc_ch.size())
	rd.compute_list_dispatch(cl, groups, 1, 1)


# --- helpers ------------------------------------------------------------------

func _compile(path: String) -> RID:
	var sf: RDShaderFile = load(path)
	return _rd.shader_create_from_spirv(sf.get_spirv())

# Uniform-set builder: list of [binding, rid] -> uniform_set_create against `shader` at set 0.
func _uset(shader: RID, entries: Array) -> RID:
	var uniforms: Array = []
	for e in entries:
		var u: RDUniform = RDUniform.new()
		u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		u.binding = int(e[0])
		u.add_id(e[1])
		uniforms.append(u)
	return _rd.uniform_set_create(uniforms, shader, 0)

# Params { uint cell_count; uint pad0; uint pad1; uint pad2; } — o2/co2 transport + wind_pressure.
func _pc_cellcount(cc: int) -> PackedByteArray:
	return PackedInt32Array([cc, 0, 0, 0]).to_byte_array()

# Params { uint cell_count; float pvx; float pvz; float dt; uint buoy; uint pad0; uint pad1; uint pad2; } — wind_step.
func _pc_windstep(cc: int, pvx: float, pvz: float, dt: float, buoy: int) -> PackedByteArray:
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(32)
	pc.encode_u32(0, cc)
	pc.encode_float(4, pvx)
	pc.encode_float(8, pvz)
	pc.encode_float(12, dt)
	pc.encode_u32(16, buoy)
	pc.encode_u32(20, 0)
	pc.encode_u32(24, 0)
	pc.encode_u32(28, 0)
	return pc

# Params { uint cell_count; float dt; float pad0; float pad1; } — charge_accum.
func _pc_charge(cc: int, dt: float) -> PackedByteArray:
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(16)
	pc.encode_u32(0, cc)
	pc.encode_float(4, dt)
	pc.encode_float(8, 0.0)
	pc.encode_float(12, 0.0)
	return pc
