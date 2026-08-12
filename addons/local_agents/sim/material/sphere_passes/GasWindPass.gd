extends RefCounted


const WIND_PRESSURE_PATH: String = "res://addons/local_agents/sim/material/kernels3d/wind_pressure_sphere3d.glsl"
const WIND_STEP_PATH: String = "res://addons/local_agents/sim/material/kernels3d/wind_step_sphere3d.glsl"
# ONE TRANSPORT KERNEL FOR EVERY GAS. o2_transport_sphere3d.glsl and co2_transport_sphere3d.glsl were the
# not, on a stated limitation of the lattice that did not exist.
const TRACER_TRANSPORT_PATH: String = "res://addons/local_agents/sim/material/kernels3d/tracer_transport_sphere3d.glsl"

# Still-air settling velocity per unit of fractional molar-mass excess over dry air, m/s. Gravitational
# separation of a turbulent atmosphere is weak; this models a dense gas pooling in still air.
const SETTLE_V_PER_CONTRAST: float = 0.05
const EDDY_DIFFUSE: float = 0.02
const GASES: Array = [
	{"channel": "o2", "contrast": 0.10460},    # O2  31.998 vs dry air 28.968
	{"channel": "co2", "contrast": 0.51927},   # CO2 44.010 vs dry air 28.968
]
const CHARGE_ACCUM_PATH: String = "res://addons/local_agents/sim/material/kernels3d/charge_accum_sphere3d.glsl"

# --- default constants used when a scalar is not supplied in ctx (NOTE any default picked) -------------------
# pascals and pass B computes a real m/s^2 acceleration, integrating either of them against a game-second
const DEFAULT_DT: float = 0.1          # fallback only; converted to real seconds below
const DEFAULT_BUOY: float = 1.0        # buoyancy enabled (1) when ctx has no "buoy"

var _rd: RenderingDevice = null
var _cc: int = 0
var _columns: int = 0            # surf_count = cell_count / depth — wind_pressure's thread count
var _col_groups: int = 0         # dispatch groups for the per-COLUMN pressure kernel

# shaders + pipelines
var _wp_shader: RID = RID()
var _wp_pipe: RID = RID()
var _ws_shader: RID = RID()
var _ws_pipe: RID = RID()
var _gas_shader: RID = RID()
var _gas_pipe: RID = RID()
var _ch_shader: RID = RID()
var _ch_pipe: RID = RID()
var _dump: RID = RID()

# uniform sets, one per ping-pong parity (index 0 and 1)
var _wp_set: Array = [RID(), RID()]
var _ws_set: Array = [RID(), RID()]
# One uniform set per gas per parity: _gas_sets[gas_index][parity].
var _gas_sets: Array = []
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
	_gas_shader = _compile(TRACER_TRANSPORT_PATH)
	_gas_pipe = _rd.compute_pipeline_create(_gas_shader)
	_ch_shader = _compile(CHARGE_ACCUM_PATH)
	_ch_pipe = _rd.compute_pipeline_create(_ch_shader)

	var temp: Array = bufs["temp"]     # PAIR
	var o2: Array = bufs["o2"]         # PAIR
	var co2: Array = bufs["co2"]       # PAIR
	# Charge separation feeds on supercooled condensate aloft. cloud/fog are no longer stored (Phase 2a
	# collapsed them into `moisture`); the total suspended water is a fine moisture proxy for the updraft ×
	# cloud charge term (behavioural, perf-over-parity).
	var cloud: Array = bufs["moisture"]   # PAIR (was "cloud"; now the unified moisture channel)
	var air: Array = bufs["air"]       # PAIR — conserved air mass; pressure is its weight (see wind_pressure)
	var solid: RID = bufs["solid"]     # SINGLE
	var pressure: RID = bufs["pressure"]
	var vx: RID = bufs["vel_x"]
	var vy: RID = bufs["vel_y"]
	var vz: RID = bufs["vel_z"]
	var charge: RID = bufs["charge"]
	var nbr: RID = bufs["nbr"]
	var partner_rid: RID = bufs.get("link_partner", RID())
	# A write-only sink for bindings the kernel declares but this pass never uses. Never read back.
	if not _dump.is_valid():
		var z: PackedByteArray = PackedByteArray()
		z.resize(cc * 4)
		_dump = _rd.storage_buffer_create(z.size(), z)
	var radial: RID = bufs["radial"]  # per-cell outward unit vector (latitude, for Coriolis handedness)
	# Per-column tangent-frame table: the direction of each lateral link in the cell's OWN (tan_a, tan_b) axes.
	# The wind kernels store momentum in that frame, so they read directions from here, never from slot order.
	var ltan: RID = bufs["link_tan"]

	_gas_sets = []
	for _gi in GASES.size():
		_gas_sets.append([RID(), RID()])
	for p in 2:
		var back: int = 1 - p
		# wind_pressure: 0=AirIn(live), 1=AirOut(back), 2=TempIn(live), 3=Solid, 4=PressureOut, 5=VelX, 6=VelZ, 15=Neigh
		_wp_set[p] = _uset(_wp_shader, [[0, air[p]], [1, air[back]], [2, temp[p]], [3, solid],
				[4, pressure], [5, vx], [6, vz], [15, nbr], [17, partner_rid], [16, ltan]])
		# wind_step: 0=PressureIn, 1=TempIn(live), 2=Solid, 3=VelX, 4=VelY, 5=VelZ, 6=AirIn(back), 14=Radial, 15=Neigh
		_ws_set[p] = _uset(_ws_shader, [[0, pressure], [1, temp[p]], [2, solid], [3, vx], [4, vy], [5, vz],
				[6, air[back]], [14, radial], [15, nbr], [17, partner_rid], [16, ltan]])
		# gas_transport, one set per gas: 0=GasIn(live), 1=GasOut(back), 2=Solid, 3/4/5=Vel, 15=Neigh, 16=LinkTan.
		for gi in GASES.size():
			var ch: Array = bufs[String(GASES[gi]["channel"])]
			# 2 = Deposit. A gas has no settled phase so it is never written, but it must NOT be the gas's own
			# out buffer: the kernel declares both `restrict`, which promises the driver they do not alias.
			# Binding one buffer to both is undefined behaviour whether or not the second is written.
			_gas_sets[gi][p] = _uset(_gas_shader, [[0, ch[p]], [1, ch[back]], [2, _dump], [3, solid],
					[4, vx], [5, vy], [6, vz], [15, nbr], [17, partner_rid], [16, ltan]])
		# charge_accum: 0=Charge(single, in place), 1=TempIn(live), 2=CloudIn(live), 3=VelY, 4=Solid.
		#  slower clock than a near one. Deleted — see MaterialSphereGPU3D.gd's header note.)
		_ch_set[p] = _uset(_ch_shader, [[0, charge], [1, temp[p]], [2, cloud[p]], [3, vy], [4, solid]])


func dispatch(rd: RenderingDevice, cl: int, parity: int, ctx: Dictionary, cc: int, groups: int) -> void:
	if _rd == null:
		return
	var p: int = parity
	# REAL seconds, from the one function that already knows what a field step is worth. Everything
	# downstream of this line is SI. (ctx["dt"] is STEP_DT, 0.1 GAME seconds, and is deliberately not used.)
	var dt: float = LAMaterialFieldSphereStep3D.real_seconds_per_step()
	# Courant factor for the tracer transport: v*dt/dx, so REAL seconds over the cell's size in REAL METRES.
	# The velocity field is m/s as of the pascal migration, so dividing by a MODEL-unit cell size would be
	# 168.6x too large and every cell would sit pinned against the CFL cap.
	var cell_m: float = float(ctx.get("cell_size", 1.0)) * LAPhysical.METRES_PER_MODEL_UNIT
	var k_courant: float = dt / cell_m if cell_m != 0.0 else 0.0
	var buoy_on: int = 1 if float(ctx.get("buoy", DEFAULT_BUOY)) >= 0.5 else 0
	# Planet spin axis (north pole) in the field frame — drives latitude, banded zonal flow + Coriolis handedness.
	# The current planet's pole is world +Y (matches the terrain's radial snow-line convention); ctx may override.
	var spin: Vector3 = ctx.get("spin_axis", Vector3(0.0, 1.0, 0.0))

	var step_index: int = int(ctx.get("step_index", 0))
	# PASS A runs one thread per radial COLUMN, so its dispatch is cell_count/depth threads, not cell_count.
	var depth: int = maxi(int(ctx.get("depth", 1)), 1)
	_columns = cc / depth
	_col_groups = int(ceil(float(_columns) / 64.0))

	var pc_cc: PackedByteArray = _pc_cellcount(cc, depth)       # {cell_count, depth, pad, pad}
	var pc_wp: PackedByteArray = _pc_windpressure(_columns, depth,
			float(ctx.get("core_radius", 0.0)), float(ctx.get("cell_size", 1.0)),
			float(ctx.get("sea_radius", 0.0)), dt, step_index)
	var pc_ws: PackedByteArray = _pc_windstep(cc, dt, buoy_on, spin, depth,
			float(ctx.get("core_radius", 0.0)), float(ctx.get("cell_size", 1.0)), float(ctx.get("sea_radius", 0.0)))
	var pc_ch: PackedByteArray = _pc_charge(cc, dt)

	rd.compute_list_bind_compute_pipeline(cl, _wp_pipe)
	rd.compute_list_bind_uniform_set(cl, _wp_set[p], 0)
	rd.compute_list_set_push_constant(cl, pc_wp, pc_wp.size())
	rd.compute_list_dispatch(cl, _col_groups, 1, 1)
	rd.compute_list_add_barrier(cl)   # wind_step reads the pressure field written above

	# 2) wind_step (PASS B): pressure gradient -> velocity, in place on vel_x/y/z.
	rd.compute_list_bind_compute_pipeline(cl, _ws_pipe)
	rd.compute_list_bind_uniform_set(cl, _ws_set[p], 0)
	rd.compute_list_set_push_constant(cl, pc_ws, pc_ws.size())
	rd.compute_list_dispatch(cl, groups, 1, 1)
	rd.compute_list_add_barrier(cl)   # o2/co2 advection + charge updraft read the fresh velocity

	# 3) gas_transport, once per gas. Same pipeline, same push layout, one float different — which is exactly
	# what a per-gas kernel was hiding. Independent of each other and of charge below.
	for gi in GASES.size():
		rd.compute_list_bind_compute_pipeline(cl, _gas_pipe)
		rd.compute_list_bind_uniform_set(cl, _gas_sets[gi][p], 0)
		var pc_gas: PackedByteArray = _pc_tracer(cc, depth, k_courant,
				SETTLE_V_PER_CONTRAST * float(GASES[gi]["contrast"]), EDDY_DIFFUSE, 0)
		rd.compute_list_set_push_constant(cl, pc_gas, pc_gas.size())
		rd.compute_list_dispatch(cl, groups, 1, 1)

	# 4) charge_accum: per-cell charge separation in place (reads fresh vel_y + live cloud/temp). Touches only
	# the charge buffer, so it does NOT conflict with the o2/co2 transport above — no barrier needed between them.
	rd.compute_list_bind_compute_pipeline(cl, _ch_pipe)
	rd.compute_list_bind_uniform_set(cl, _ch_set[p], 0)
	rd.compute_list_set_push_constant(cl, pc_ch, pc_ch.size())
	rd.compute_list_dispatch(cl, groups, 1, 1)


## Free every RID this pass owns (uniform sets, then pipelines, then shaders), dependent-first, before the
## driver drops the local RenderingDevice. All buffer bindings are borrowed from the driver's bufs (none owned here).
func dispose(rd: RenderingDevice) -> void:
	if rd == null:
		return
	for gs: Array in _gas_sets:
		for r: RID in gs:
			if r.is_valid():
				_rd.free_rid(r)
	_gas_sets = []
	for s: Array in [_wp_set, _ws_set, _ch_set]:
		for r in s:
			if r is RID and r.is_valid():
				rd.free_rid(r)
	_wp_set = [RID(), RID()]
	_ws_set = [RID(), RID()]

	_ch_set = [RID(), RID()]
	for r: RID in [_wp_pipe, _ws_pipe, _gas_pipe, _ch_pipe,
			_wp_shader, _ws_shader, _gas_shader, _ch_shader]:
		if r.is_valid():
			rd.free_rid(r)
	_wp_pipe = RID()
	_ws_pipe = RID()
	_gas_pipe = RID()
	_ch_pipe = RID()
	_wp_shader = RID()
	_ws_shader = RID()
	_gas_shader = RID()
	_ch_shader = RID()


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

# Params { uint cell_count; uint depth; float k; float settle_v; float diffuse; uint deposit; uint pad0;
# uint pad1; } — tracer_transport, shared with FireDustPass. `k` is the Courant factor dt/cell_size in REAL
# units; `settle_v` is the still-air settling velocity in m/s, signed: >0 sinks, <0 rises.
func _pc_tracer(cc: int, depth: int, k: float, settle_v: float, diffuse: float, deposit: int) -> PackedByteArray:
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(32)
	pc.encode_u32(0, cc)
	pc.encode_u32(4, depth)
	pc.encode_float(8, k)
	pc.encode_float(12, settle_v)
	pc.encode_float(16, diffuse)
	pc.encode_u32(20, deposit)
	pc.encode_u32(24, 0)
	pc.encode_u32(28, 0)
	return pc

# Params { uint cell_count; uint depth; uint pad1; uint pad2; } — legacy cellcount push. `depth` turns a
# cell index into its COLUMN and read the per-column tangent-frame table; o2 diffuses symmetrically and ignores it.
func _pc_cellcount(cc: int, depth: int) -> PackedByteArray:
	return PackedInt32Array([cc, depth, 0, 0]).to_byte_array()

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
