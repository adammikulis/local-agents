extends "res://addons/local_agents/sim/material/sphere_passes/SpherePass.gd"


const CONDUCT_PATH: String = "res://addons/local_agents/sim/material/kernels3d/heat_sphere3d.glsl"
const COPY_PATH: String = "res://addons/local_agents/sim/material/kernels3d/copy_sphere3d.glsl"
const SOLAR_PATH: String = "res://addons/local_agents/sim/material/kernels3d/heat3d_solar_sphere3d.glsl"
const BUOY_PATH: String = "res://addons/local_agents/sim/material/kernels3d/heat3d_buoyancy_sphere3d.glsl"
const LAVA_PHASE_PATH: String = "res://addons/local_agents/sim/material/kernels3d/lava_phase_sphere3d.glsl"
const MAGMA_PATH: String = "res://addons/local_agents/sim/material/kernels3d/magma_buoy_sphere3d.glsl"

const BandsScript: GDScript = preload("res://addons/local_agents/sim/material/AbsorptionBands.gd")
const CellListScript: GDScript = preload("res://addons/local_agents/sim/material/sphere_passes/CellListPass.gd")

var _conduct_pipe: RID = RID()
var _copy_pipe: RID = RID()
var _solar_pipe: RID = RID()
var _buoy_pipe: RID = RID()
var _lava_phase_pipe: RID = RID()
var _magma_pipe: RID = RID()

# Per-parity uniform sets (index = parity p).
var _conduct_set: Array = [RID(), RID()]   # temp[p] -> _cond_scratch
var _copy_set: Array = [RID(), RID()]      # _cond_scratch -> temp[p]
var _solar_set: Array = [RID(), RID()]
var _buoy_set: Array = [RID(), RID()]
var _lava_phase_set: Array = [RID(), RID()]
var _magma_set: Array = [RID(), RID()]

# Private scratch: the conduction gather target (net-zero-flip copy-back) and the magma two-pass snapshots.
var _cond_scratch: RID = RID()
var _magma_scratch: RID = RID()
var _temp_snap: RID = RID()
# Receiver-indexed radiative deposit, cc*6 floats at cell*6 + slot. Written by the emit dispatch, consumed
# and zeroed by the deposit dispatch in the same step, so every slot has exactly one writer.
var _rad_dep: RID = RID()

# Band edges, per-band absorption coefficients and the Planck CDF the radiative kernel reads.
var _rad_table: RID = RID()
var _band_count: int = 0

# BORROWED (owned by the driver): the dispatch-indirect argument buffer CellListPass publishes each step.
# Held as a field because dispatch() needs the RID, and it is the same buffer for both parities.
var _active_args: RID = RID()


func _setup(bufs: Dictionary, cc: int) -> void:
	_conduct_pipe = _kernel(CONDUCT_PATH)
	_copy_pipe = _kernel(COPY_PATH)
	_solar_pipe = _kernel(SOLAR_PATH)
	_buoy_pipe = _kernel(BUOY_PATH)
	_lava_phase_pipe = _kernel(LAVA_PHASE_PATH)
	_magma_pipe = _kernel(MAGMA_PATH)

	_magma_scratch = _scratch(cc)
	_cond_scratch = _scratch(cc)
	_temp_snap = _scratch(cc)
	_rad_dep = _scratch(cc * 6)

	_band_count = BandsScript.BAND_COUNT
	_rad_table = _storage_buffer(BandsScript.packed().to_byte_array())

	var solid: RID = _single(bufs, "solid")
	var nbr: RID = _single(bufs, "nbr")
	var radial: RID = _single(bufs, "radial")
	var shell: RID = _single(bufs, "shell")
	var cell_vol: RID = _single(bufs, "cell_vol")
	var temp: Array = _pair(bufs, "temp")
	var water: Array = _pair(bufs, "water")
	var lava: Array = _pair(bufs, "lava")
	# Compacted active-cell list for the lava_phase leg (built by CellListPass earlier in the same step).
	var active_idx: RID = _single(bufs, "active_idx")
	_active_args = _single(bufs, "active_args")

	for p in 2:
		var back: int = 1 - p
		var temp_live: RID = temp[p]
		var temp_back: RID = temp[back]
		var water_back: RID = water[back]
		var lava_back: RID = lava[back]
		var shared_carriers: Array = [
			[30, _pair(bufs, "sediment")[p]], [31, _pair(bufs, "susp")[p]], [32, _pair(bufs, "dust")[p]],
			[33, _single(bufs, "carbonate")], [34, _single(bufs, "silica")], [35, _pair(bufs, "soil")[p]],
			[36, _pair(bufs, "moisture")[p]], [37, _pair(bufs, "fungus")[p]],
			[38, _single(bufs, "porosity")]]

		_conduct_set[p] = _uset(_conduct_pipe, [
			[0, temp_live], [1, _cond_scratch], [2, nbr], [3, solid],
			[4, _single(bufs, "snow")], [5, water_back], [6, _single(bufs, "rock_fill")],
			[39, shell], [20, lava_back], [21, _single(bufs, "fuel")], [22, _single(bufs, "biomass")],
			[23, _single(bufs, "detritus")]]
			+ shared_carriers)
		# copy: 0 = scratch, 1 = temp LIVE.
		_copy_set[p] = _uset(_copy_pipe, [
			[0, _cond_scratch], [1, temp_live]])
		# solar: 0 = temp (LIVE, in-place, one thread per column), 7 = pressure, 14 = radial, 39 = shell,
		# 47 = the absorption-band table, 43 = co2 (LIVE — GasWind steps it later in the same step).
		_solar_set[p] = _uset(_solar_pipe, [
			[0, temp_live], [1, solid],
			[4, _single(bufs, "snow")], [5, water_back], [6, _single(bufs, "rock_fill")],
			[7, _single(bufs, "pressure")],
			[14, radial], [39, shell], [27, _single(bufs, "biomass")],
			[47, _rad_table], [43, _pair(bufs, "co2")[p]],
			[20, lava_back], [21, _single(bufs, "fuel")], [23, _single(bufs, "detritus")]]
			+ shared_carriers)
		# buoyancy: 0 = TempIn (LIVE), 1 = TempOut (BACK), 2 = solid, the material mix 4 = snow, 5 = water,
		# 6 = rock_fill, 39 = shell (the dz the adiabat is taken over), 40 = cell volumes.
		# 20-23 = the carriers rc_shared.glsli needs; this kernel reads none of them itself.
		_buoy_set[p] = _uset(_buoy_pipe, [
			[0, temp_live], [1, temp_back], [2, solid],
			[4, _single(bufs, "snow")], [5, water_back], [6, _single(bufs, "rock_fill")],
			[39, shell], [40, cell_vol],
			[20, lava_back], [21, _single(bufs, "fuel")], [22, _single(bufs, "biomass")],
			[23, _single(bufs, "detritus")]]
			+ shared_carriers)
		# lava_phase: 0 = lava (BACK, in-place), 1 = temp (BACK, in-place), 2 = solid, 3 = the
		# receiver-indexed radiative deposit, 4 = the compacted active list, 5 = its args, 15 = nbr,
		# 17 = the reverse-link table, and the carriers rc_shared.glsli needs.
		_lava_phase_set[p] = _uset(_lava_phase_pipe, [
			[0, lava_back], [1, temp_back], [2, solid], [3, _rad_dep],
			[4, active_idx], [5, _active_args], [15, nbr],
			[17, _single(bufs, "link_partner")],
			[6, _single(bufs, "rock_fill")], [7, water_back], [21, _single(bufs, "fuel")],
			[22, _single(bufs, "biomass")], [23, _single(bufs, "detritus")], [24, _single(bufs, "snow")]]
			+ shared_carriers)
		# magma: 0 = lava (BACK, rw), 1 = lava snapshot, 2 = temp (BACK, carry-heat), 41 = temp snapshot,
		# 3 = solid, 15 = nbr, 40 = cell volumes.
		_magma_set[p] = _uset(_magma_pipe, [
			[0, lava_back], [1, _magma_scratch], [2, temp_back], [41, _temp_snap],
			[3, solid], [15, nbr], [40, cell_vol]])


func dispatch(rd: RenderingDevice, cl: int, parity: int, ctx: Dictionary, cc: int, groups: int) -> void:
	if not _dispatchable():
		return
	var sun_dir: Vector3 = ctx.get("sun_dir", Vector3(0.0, 1.0, 0.0))
	var depth: int = _ctx_depth(ctx)
	var lat_dx: float = _ctx_num(ctx, "lat_size")
	var cell_m: float = _ctx_cell_size(ctx)
	var dt_s: float = LAMaterialFieldSphereStep3D.real_seconds_per_step()
	var core_boundary_c: float = float(ctx.get("core_boundary_c", 0.0))
	var columns: int = cc / depth
	var col_groups: int = int(ceil(float(columns) / 64.0))

	# 0. CONDUCTION — gather into the private scratch, then copy back onto temp LIVE.
	var cond_pc: PackedByteArray = _conduct_pc(cc, core_boundary_c, dt_s, depth, lat_dx)
	rd.compute_list_bind_compute_pipeline(cl, _conduct_pipe)
	rd.compute_list_bind_uniform_set(cl, _conduct_set[parity], 0)
	rd.compute_list_set_push_constant(cl, cond_pc, cond_pc.size())
	rd.compute_list_dispatch(cl, groups, 1, 1)
	rd.compute_list_add_barrier(cl)          # conducted temp (scratch) visible to the copy-back
	rd.compute_list_bind_compute_pipeline(cl, _copy_pipe)
	rd.compute_list_bind_uniform_set(cl, _copy_set[parity], 0)
	var copy_pc: PackedByteArray = _pc_cells(cc)
	rd.compute_list_set_push_constant(cl, copy_pc, copy_pc.size())
	rd.compute_list_dispatch(cl, groups, 1, 1)
	rd.compute_list_add_barrier(cl)          # temp LIVE now carries conduction, feeds radiation

	# 1. RADIATION — band-resolved two-stream, one thread per column, in-place on temp LIVE.
	rd.compute_list_bind_compute_pipeline(cl, _solar_pipe)
	rd.compute_list_bind_uniform_set(cl, _solar_set[parity], 0)
	var solar_pc: PackedByteArray = _solar_pc(columns, sun_dir, dt_s, depth)
	rd.compute_list_set_push_constant(cl, solar_pc, solar_pc.size())
	rd.compute_list_dispatch(cl, col_groups, 1, 1)
	rd.compute_list_add_barrier(cl)          # radiative output (temp LIVE) visible to the buoyancy gather

	# 2. CONVECTIVE ADJUSTMENT — one thread per radial COLUMN, temp LIVE -> temp BACK.
	rd.compute_list_bind_compute_pipeline(cl, _buoy_pipe)
	rd.compute_list_bind_uniform_set(cl, _buoy_set[parity], 0)
	var buoy_pc: PackedByteArray = _buoy_pc(columns, depth)
	rd.compute_list_set_push_constant(cl, buoy_pc, buoy_pc.size())
	rd.compute_list_dispatch(cl, col_groups, 1, 1)
	rd.compute_list_add_barrier(cl)          # buoyancy output (temp BACK) committed before the lava passes read it

	# 3. LAVA PHASE — two-pass radiative exchange. Mode 0 cools the molten cells over the compacted active
	# list and aims each joule at a receiver slot; mode 1 lands them, over every cell.
	rd.compute_list_bind_compute_pipeline(cl, _lava_phase_pipe)
	rd.compute_list_bind_uniform_set(cl, _lava_phase_set[parity], 0)
	var emit_pc: PackedByteArray = _lava_phase_pc(cc, dt_s, cell_m, 0)
	rd.compute_list_set_push_constant(cl, emit_pc, emit_pc.size())
	rd.compute_list_dispatch_indirect(cl, _active_args, 0)
	rd.compute_list_add_barrier(cl)          # the aimed deposits visible to the gather
	rd.compute_list_bind_compute_pipeline(cl, _lava_phase_pipe)
	rd.compute_list_bind_uniform_set(cl, _lava_phase_set[parity], 0)
	var deposit_pc: PackedByteArray = _lava_phase_pc(cc, dt_s, cell_m, 1)
	rd.compute_list_set_push_constant(cl, deposit_pc, deposit_pc.size())
	rd.compute_list_dispatch(cl, groups, 1, 1)
	rd.compute_list_add_barrier(cl)          # post-phase lava/temp visible to the magma snapshot

	# 4. MAGMA — two-pass buoyant overpressure up-flow. Pass 0 writes the lava and temp snapshots the gather
	# reads, so pass 1's result does not depend on which cell the GPU scheduled first.
	for pass_id in 2:
		rd.compute_list_bind_compute_pipeline(cl, _magma_pipe)
		rd.compute_list_bind_uniform_set(cl, _magma_set[parity], 0)
		var magma_pc: PackedByteArray = _magma_pc(cc, pass_id)
		rd.compute_list_set_push_constant(cl, magma_pc, magma_pc.size())
		rd.compute_list_dispatch(cl, groups, 1, 1)
		rd.compute_list_add_barrier(cl)


# --- helpers ---------------------------------------------------------------------------------------------

# heat3d_solar Params: { uint column_count; float dt_s; uint depth; uint band_count;
#                        float sun_x, sun_y, sun_z; float pad0; } — 32 bytes.
func _solar_pc(columns: int, sun_dir: Vector3, dt_s: float, depth: int) -> PackedByteArray:
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(32)
	pc.encode_u32(0, columns)
	pc.encode_float(4, dt_s)
	pc.encode_u32(8, depth)
	pc.encode_u32(12, _band_count)
	pc.encode_float(16, sun_dir.x)
	pc.encode_float(20, sun_dir.y)
	pc.encode_float(24, sun_dir.z)
	pc.encode_float(28, 0.0)
	return pc


# heat_sphere Params: { uint cell_count; float core_boundary_c; float dt_s; uint depth; float lat_dx; }
# — 20 bytes. lat_dx is the lateral centre-to-centre run in model units; the radial runs come from the
# shell table.
func _conduct_pc(cc: int, core_boundary_c: float, dt_s: float, depth: int,
		lat_dx: float) -> PackedByteArray:
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(20)
	pc.encode_u32(0, cc)
	pc.encode_float(4, core_boundary_c)
	pc.encode_float(8, dt_s)
	pc.encode_u32(12, depth)
	pc.encode_float(16, lat_dx)
	return pc


# heat3d_buoyancy Params: { uint column_count; uint depth; uint pad0; uint pad1; } — 16 bytes.
func _buoy_pc(columns: int, depth: int) -> PackedByteArray:
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(16)
	pc.encode_u32(0, columns)
	pc.encode_u32(4, depth)
	pc.encode_u32(8, 0)
	pc.encode_u32(12, 0)
	return pc


# lava_phase Params: { uint cell_count; float dt_s; float cell_m; uint mode; } — 16 bytes.
# mode 0 = emit, 1 = deposit. The kernel turns an exposed-face flux in W/m^2 into a temperature, so it
# needs the step's real seconds and the cell size in METRES.
func _lava_phase_pc(cc: int, dt_s: float, cell_m: float, mode: int) -> PackedByteArray:
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(20)
	pc.encode_u32(0, cc)
	pc.encode_float(4, dt_s)
	pc.encode_float(8, cell_m)
	pc.encode_u32(12, mode)
	pc.encode_float(16, CellListScript.LAVA_MIN_MASS)
	return pc


# magma_buoy Params: { uint cell_count; uint pass_id; uint pad0; uint pad1; } — 16 bytes.
func _magma_pc(cc: int, pass_id: int) -> PackedByteArray:
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(16)
	pc.encode_u32(0, cc)
	pc.encode_u32(4, pass_id)
	pc.encode_u32(8, 0)
	pc.encode_u32(12, 0)
	return pc
