extends "res://addons/local_agents/sim/material/sphere_passes/SpherePass.gd"


const Tracer = preload("res://addons/local_agents/sim/material/sphere_passes/TracerTransport.gd")

const WIND_PRESSURE_PATH: String = "res://addons/local_agents/sim/material/kernels3d/wind_pressure_sphere3d.glsl"
const WIND_STEP_PATH: String = "res://addons/local_agents/sim/material/kernels3d/wind_step_sphere3d.glsl"
const CHARGE_ACCUM_PATH: String = "res://addons/local_agents/sim/material/kernels3d/charge_accum_sphere3d.glsl"

## One row per transported gas. The settling velocity follows from the molar mass alone, through the same
## contrast law every tracer uses, so a gas is a channel name and a substance property and nothing else.
const GASES: Array = [
	{"channel": "o2", "molar_mass": LAPhysical.MOLAR_MASS_O2_KG_MOL},
	{"channel": "co2", "molar_mass": LAPhysical.MOLAR_MASS_CO2_KG_MOL},
]

## Buoyancy term enabled when ctx carries no "buoy".
const DEFAULT_BUOY: float = 1.0

var _wp_pipe: RID = RID()
var _ws_pipe: RID = RID()
var _gas_pipe: RID = RID()
var _ch_pipe: RID = RID()

# Uniform sets, one per ping-pong parity (index 0 and 1).
var _wp_set: Array = [RID(), RID()]
var _ws_set: Array = [RID(), RID()]
# One uniform set per gas per parity: _gas_sets[gas_index][parity].
var _gas_sets: Array = []
var _ch_set: Array = [RID(), RID()]


func _setup(bufs: Dictionary, _cc: int) -> void:
	_wp_pipe = _kernel(WIND_PRESSURE_PATH)
	_ws_pipe = _kernel(WIND_STEP_PATH)
	_gas_pipe = _kernel(Tracer.KERNEL_PATH)
	_ch_pipe = _kernel(CHARGE_ACCUM_PATH)

	var temp: Array = _pair(bufs, "temp")
	# Charge separation feeds on supercooled condensate aloft; total suspended water is the moisture proxy
	# for the updraft × cloud charge term (behavioural, perf-over-parity).
	var cloud: Array = _pair(bufs, "moisture")
	var air: Array = _pair(bufs, "air")      # conserved air mass; pressure is its weight (see wind_pressure)
	var solid: RID = _single(bufs, "solid")
	var pressure: RID = _single(bufs, "pressure")
	var vx: RID = _single(bufs, "vel_x")
	var vy: RID = _single(bufs, "vel_y")
	var vz: RID = _single(bufs, "vel_z")
	var charge: RID = _single(bufs, "charge")
	var nbr: RID = _single(bufs, "nbr")
	var radial: RID = _single(bufs, "radial")   # per-cell outward unit vector (latitude, Coriolis handedness)
	# Per-column tangent-frame table: the direction of each lateral link in the cell's OWN (tan_a, tan_b) axes.
	# The wind kernels store momentum in that frame, so they read directions from here, never from slot order.
	var ltan: RID = _single(bufs, "link_tan")

	_gas_sets = []
	for _gi in GASES.size():
		_gas_sets.append([RID(), RID()])
	for p in 2:
		var back: int = 1 - p
		# wind_pressure: 0=AirIn(live), 1=AirOut(back), 2=TempIn(live), 3=Solid, 4=PressureOut, 5=VelX, 6=VelZ, 15=Neigh
		_wp_set[p] = _uset(_wp_pipe, [[0, air[p]], [1, air[back]], [2, temp[p]], [3, solid],
				[4, pressure], [5, vx], [6, vz], [15, nbr], [16, ltan]])
		# wind_step: 0=PressureIn, 1=TempIn(live), 2=Solid, 3=VelX, 4=VelY, 5=VelZ, 6=AirIn(back), 14=Radial, 15=Neigh
		_ws_set[p] = _uset(_ws_pipe, [[0, pressure], [1, temp[p]], [2, solid], [3, vx], [4, vy], [5, vz],
				[6, air[back]], [14, radial], [15, nbr], [16, ltan]])
		# One tracer_transport set per gas. A gas has no settled phase, so the deposit binding takes the gas's
		# own back buffer and is never written.
		for gi in GASES.size():
			var ch: Array = _pair(bufs, String(GASES[gi]["channel"]))
			_gas_sets[gi][p] = _uset(_gas_pipe, Tracer.bindings(bufs, ch[p], ch[back], ch[back]))
		# charge_accum: 0=Charge(single, in place), 1=TempIn(live), 2=CloudIn(live), 3=VelY, 4=Solid.
		_ch_set[p] = _uset(_ch_pipe, [[0, charge], [1, temp[p]], [2, cloud[p]], [3, vy], [4, solid]])


func dispatch(rd: RenderingDevice, cl: int, parity: int, ctx: Dictionary, cc: int, groups: int) -> void:
	if not _dispatchable():
		return
	var p: int = parity
	# REAL seconds, from the one function that already knows what a field step is worth. Everything
	# downstream of this line is SI. (ctx["dt"] is STEP_DT, in GAME seconds, and is deliberately not used.)
	var dt: float = LAMaterialFieldSphereStep3D.real_seconds_per_step()
	var cell_size: float = _ctx_cell_size(ctx)
	var k_courant: float = Tracer.courant(cell_size)
	var buoy_on: int = 1 if float(ctx.get("buoy", DEFAULT_BUOY)) >= 0.5 else 0
	# Planet spin axis (north pole) in the field frame — drives latitude, banded zonal flow + Coriolis handedness.
	# The current planet's pole is world +Y (matches the terrain's radial snow-line convention); ctx may override.
	var spin: Vector3 = ctx.get("spin_axis", Vector3(0.0, 1.0, 0.0))

	var step_index: int = int(ctx.get("step_index", 0))
	var core_radius: float = _ctx_core_radius(ctx)
	var sea_radius: float = _ctx_num(ctx, "sea_radius")
	# PASS A runs one thread per radial COLUMN, so its dispatch is cell_count/depth threads, not cell_count.
	var depth: int = _ctx_depth(ctx)
	var columns: int = cc / depth
	var col_groups: int = int(ceil(float(columns) / 64.0))

	var pc_wp: PackedByteArray = _pc_windpressure(columns, depth, core_radius, cell_size,
			sea_radius, dt, step_index)
	var pc_ws: PackedByteArray = _pc_windstep(cc, dt, buoy_on, spin, depth, core_radius, cell_size, sea_radius)
	var pc_ch: PackedByteArray = _pc_charge(cc, dt)

	rd.compute_list_bind_compute_pipeline(cl, _wp_pipe)
	rd.compute_list_bind_uniform_set(cl, _wp_set[p], 0)
	rd.compute_list_set_push_constant(cl, pc_wp, pc_wp.size())
	rd.compute_list_dispatch(cl, col_groups, 1, 1)
	rd.compute_list_add_barrier(cl)   # wind_step reads the pressure field written above

	# 2) wind_step (PASS B): pressure gradient -> velocity, in place on vel_x/y/z.
	rd.compute_list_bind_compute_pipeline(cl, _ws_pipe)
	rd.compute_list_bind_uniform_set(cl, _ws_set[p], 0)
	rd.compute_list_set_push_constant(cl, pc_ws, pc_ws.size())
	rd.compute_list_dispatch(cl, groups, 1, 1)
	rd.compute_list_add_barrier(cl)   # o2/co2 advection + charge updraft read the fresh velocity

	# 3) tracer transport, once per gas: same pipeline, same push layout, one float different.
	# The gases are independent of each other and of charge below.
	for gi in GASES.size():
		rd.compute_list_bind_compute_pipeline(cl, _gas_pipe)
		rd.compute_list_bind_uniform_set(cl, _gas_sets[gi][p], 0)
		var pc_gas: PackedByteArray = Tracer.push_constant(cc, depth, k_courant,
				Tracer.gas_settle_v(float(GASES[gi]["molar_mass"])), Tracer.EDDY_DIFFUSE, false,
				core_radius, cell_size)
		rd.compute_list_set_push_constant(cl, pc_gas, pc_gas.size())
		rd.compute_list_dispatch(cl, groups, 1, 1)

	# 4) charge_accum: per-cell charge separation in place (reads fresh vel_y + live cloud/temp). Touches only
	# the charge buffer, so it does NOT conflict with the gas transport above — no barrier needed between them.
	rd.compute_list_bind_compute_pipeline(cl, _ch_pipe)
	rd.compute_list_bind_uniform_set(cl, _ch_set[p], 0)
	rd.compute_list_set_push_constant(cl, pc_ch, pc_ch.size())
	rd.compute_list_dispatch(cl, groups, 1, 1)


# --- helpers ------------------------------------------------------------------

# Params { uint surf_count; uint depth; float core_radius; float cell_size; float sea_radius; float dt;
#          uint step_index; uint pad0; } — wind_pressure (the per-COLUMN air/hydrostatic kernel).
# step_index == 0 tells the kernel to seed the standard atmosphere; the air channel is allocated all-zero.
func _pc_windpressure(columns: int, depth: int, core_radius: float, cell_size: float,
		sea_radius: float, dt: float, step_index: int) -> PackedByteArray:
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(32)
	pc.encode_u32(0, columns)
	pc.encode_u32(4, depth)
	pc.encode_float(8, core_radius)
	pc.encode_float(12, cell_size)
	pc.encode_float(16, sea_radius)
	pc.encode_float(20, dt)
	pc.encode_u32(24, step_index)
	pc.encode_u32(28, 0)
	return pc


# Params { uint cell_count; float dt; uint buoy; float spin_x,y,z; uint depth; float core_radius;
#          float cell_size; float sea_radius; } — 40 bytes, wind_step.
func _pc_windstep(cc: int, dt: float, buoy: int, spin: Vector3,
		depth: int, core_radius: float, cell_size: float, sea_radius: float) -> PackedByteArray:
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(40)
	pc.encode_u32(0, cc)
	pc.encode_float(4, dt)
	pc.encode_u32(8, buoy)
	pc.encode_float(12, spin.x)
	pc.encode_float(16, spin.y)
	pc.encode_float(20, spin.z)
	pc.encode_u32(24, depth)
	pc.encode_float(28, core_radius)
	pc.encode_float(32, cell_size)
	pc.encode_float(36, sea_radius)
	return pc


# Params { uint cell_count; float dt; uint pad0; float pad1; } — charge_accum.
func _pc_charge(cc: int, dt: float) -> PackedByteArray:
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(16)
	pc.encode_u32(0, cc)
	pc.encode_float(4, dt)
	pc.encode_u32(8, 0)
	pc.encode_float(12, 0.0)
	return pc
