class_name LASphereThermalPass
extends RefCounted


const CONDUCT_PATH: String = "res://addons/local_agents/sim/material/kernels3d/heat_sphere3d.glsl"
const COPY_PATH: String = "res://addons/local_agents/sim/material/kernels3d/copy_sphere3d.glsl"
const SOLAR_PATH: String = "res://addons/local_agents/sim/material/kernels3d/heat3d_solar_sphere3d.glsl"
const BUOY_PATH: String = "res://addons/local_agents/sim/material/kernels3d/heat3d_buoyancy_sphere3d.glsl"
const MAGMA_PATH: String = "res://addons/local_agents/sim/material/kernels3d/magma_buoy_sphere3d.glsl"

const BandsScript: GDScript = preload("res://addons/local_agents/sim/material/AbsorptionBands.gd")

var _cc: int = 0

var _conduct_shader: RID = RID()
var _copy_shader: RID = RID()
var _conduct_pipe: RID = RID()
var _copy_pipe: RID = RID()
var _conduct_set: Array = [RID(), RID()]   # per phase: temp[p] -> _cond_scratch
var _copy_set: Array = [RID(), RID()]      # per phase: _cond_scratch -> temp[p]
var _cond_scratch: RID = RID()             # private conduction gather target (net-zero-flip copy-back)

var _solar_shader: RID = RID()
var _buoy_shader: RID = RID()
var _magma_shader: RID = RID()

var _solar_pipe: RID = RID()
var _buoy_pipe: RID = RID()
var _magma_pipe: RID = RID()

# Per-parity uniform sets (index = parity p).
var _solar_set: Array = [RID(), RID()]
var _buoy_set: Array = [RID(), RID()]
var _magma_set: Array = [RID(), RID()]
var _snap_set: Array = [RID(), RID()]      # per phase: temp BACK -> _temp_snap

# Private lava snapshot for the magma two-pass gather (cc floats), never handed in via bufs.
var _scratch: RID = RID()

# Private temperature snapshot (cc floats). The read-IN half of the magma ping-pong: the kernel writes a
# SUBSET of cells in place, so its neighbour reads come from here instead of the buffer it is writing.
var _temp_snap: RID = RID()

# Band edges, per-band absorption coefficients and the Planck CDF the radiative kernel reads.
# LAAbsorptionBands is the one authority; this is its upload, never a second copy of the numbers.
var _rad_table: RID = RID()
var _band_count: int = 0


func setup(rd: RenderingDevice, bufs: Dictionary, cc: int) -> void:
	_cc = cc

	_solar_shader = _load_shader(rd, SOLAR_PATH)
	_solar_pipe = rd.compute_pipeline_create(_solar_shader)
	_buoy_shader = _load_shader(rd, BUOY_PATH)
	_buoy_pipe = rd.compute_pipeline_create(_buoy_shader)
	_magma_shader = _load_shader(rd, MAGMA_PATH)
	_magma_pipe = rd.compute_pipeline_create(_magma_shader)
	_conduct_shader = _load_shader(rd, CONDUCT_PATH)
	_conduct_pipe = rd.compute_pipeline_create(_conduct_shader)
	_copy_shader = _load_shader(rd, COPY_PATH)
	_copy_pipe = rd.compute_pipeline_create(_copy_shader)

	# Private lava snapshot, conduction gather scratch and temperature snapshot (cc float32, zeroed).
	var zf: PackedFloat32Array = PackedFloat32Array()
	zf.resize(cc)
	var zb: PackedByteArray = zf.to_byte_array()
	_scratch = rd.storage_buffer_create(zb.size(), zb)
	_cond_scratch = rd.storage_buffer_create(zb.size(), zb)
	_temp_snap = rd.storage_buffer_create(zb.size(), zb)

	_band_count = BandsScript.BAND_COUNT
	var table: PackedByteArray = BandsScript.packed().to_byte_array()
	_rad_table = rd.storage_buffer_create(table.size(), table)

	var solid: RID = bufs["solid"]
	var nbr: RID = bufs["nbr"]
	var radial: RID = bufs["radial"]
	var temp: Array = bufs["temp"]
	var water: Array = bufs["water"]
	var lava: Array = bufs["lava"]
	var shell: RID = bufs["shell"]

	for p in 2:
		var back: int = 1 - p
		var temp_live: RID = temp[p]
		var temp_back: RID = temp[back]
		var water_back: RID = water[back]
		var lava_back: RID = lava[back]
		var shared_carriers: Array = [
			[30, bufs["sediment"][p]], [31, bufs["susp"][p]], [32, bufs["dust"][p]],
			[33, bufs["carbonate"]], [34, bufs["silica"]], [35, bufs["soil"][p]],
			[36, bufs["moisture"][p]], [37, bufs["fungus"][p]],
			[38, bufs["porosity"]]]

		# copy: 0 = scratch, 1 = temp LIVE.
		_conduct_set[p] = _make_set(rd, _conduct_shader, [
			[0, temp_live], [1, _cond_scratch], [2, nbr], [3, solid],
			[4, bufs["snow"]], [5, water_back], [6, bufs["rock_fill"]],
			[39, shell], [20, lava_back], [21, bufs["fuel"]], [22, bufs["biomass"]],
			[23, bufs["detritus"]]]
			+ shared_carriers)
		_copy_set[p] = _make_set(rd, _copy_shader, [
			[0, _cond_scratch], [1, temp_live]])
		# solar: 0 = temp (LIVE, in-place, one thread per column), 7 = pressure, 14 = radial,
		# 47 = the absorption-band table, 43 = co2 (LIVE — GasWind steps it later in the same step).
		_solar_set[p] = _make_set(rd, _solar_shader, [
			[0, temp_live], [1, solid],
			[4, bufs["snow"]], [5, water_back], [6, bufs["rock_fill"]], [7, bufs["pressure"]],
			[14, radial], [39, shell], [27, bufs["biomass"]],
			[47, _rad_table], [43, bufs["co2"][p]],
			[20, lava_back], [21, bufs["fuel"]], [23, bufs["detritus"]]]
			+ shared_carriers)
		# buoyancy: 0 = TempIn (LIVE), 1 = TempOut (BACK), 2 = solid, the material mix 4 = snow, 5 = water,
		# 6 = rock_fill, 15 = nbr, 39 = shell (the dz the adiabat is taken over), 40 = cell volumes.
		_buoy_set[p] = _make_set(rd, _buoy_shader, [
			[0, temp_live], [1, temp_back], [2, solid],
			[4, bufs["snow"]], [5, water_back], [6, bufs["rock_fill"]],
			[39, shell], [40, bufs["cell_vol"]],
			# 20-23 = the carriers rc_shared.glsli needs; this kernel reads none of them itself.
			[20, lava_back], [21, bufs["fuel"]], [22, bufs["biomass"]], [23, bufs["detritus"]]]
			+ shared_carriers)
		# snapshot: copy_sphere3d 0 = src, 1 = dst. Feeds the read-IN half of magma.
		_snap_set[p] = _make_set(rd, _copy_shader, [
			[0, temp_back], [1, _temp_snap]])
		# magma: 0 = lava (BACK, rw), 1 = lava scratch, 2 = temp (BACK, carry-heat), 41 = temp snapshot,
		# 3 = solid, 15 = nbr.
		_magma_set[p] = _make_set(rd, _magma_shader, [
			[0, lava_back], [1, _scratch], [2, temp_back], [41, _temp_snap], [3, solid], [15, nbr],
			[40, bufs["cell_vol"]]])


func dispatch(rd: RenderingDevice, cl: int, parity: int, ctx: Dictionary, cc: int, groups: int) -> void:
	var sun_dir: Vector3 = ctx.get("sun_dir", Vector3(0.0, 1.0, 0.0))
	var depth: int = maxi(int(ctx.get("depth", 1)), 1)
	var lat_dx: float = float(ctx.get("lat_size", 0.0))
	var core_boundary_c: float = float(ctx.get("core_boundary_c", 0.0))
	var columns: int = cc / depth
	var col_groups: int = int(ceil(float(columns) / 64.0))

	var cond_pc: PackedByteArray = _conduct_pc(cc, core_boundary_c, _real_seconds_per_step(), depth, lat_dx)
	rd.compute_list_bind_compute_pipeline(cl, _conduct_pipe)
	rd.compute_list_bind_uniform_set(cl, _conduct_set[parity], 0)
	rd.compute_list_set_push_constant(cl, cond_pc, cond_pc.size())
	rd.compute_list_dispatch(cl, groups, 1, 1)
	rd.compute_list_add_barrier(cl)          # conducted temp (scratch) visible to the copy-back
	rd.compute_list_bind_compute_pipeline(cl, _copy_pipe)
	rd.compute_list_bind_uniform_set(cl, _copy_set[parity], 0)
	var copy_pc: PackedByteArray = _count_pc(cc)
	rd.compute_list_set_push_constant(cl, copy_pc, copy_pc.size())
	rd.compute_list_dispatch(cl, groups, 1, 1)
	rd.compute_list_add_barrier(cl)          # temp LIVE now carries conduction, feeds radiation

	# 1. RADIATION — one thread per column, in-place on temp LIVE.
	rd.compute_list_bind_compute_pipeline(cl, _solar_pipe)
	rd.compute_list_bind_uniform_set(cl, _solar_set[parity], 0)
	var solar_pc: PackedByteArray = _solar_pc(columns, sun_dir, _real_seconds_per_step(), depth)
	rd.compute_list_set_push_constant(cl, solar_pc, solar_pc.size())
	rd.compute_list_dispatch(cl, col_groups, 1, 1)
	rd.compute_list_add_barrier(cl)          # radiative output (temp LIVE) visible to the buoyancy gather

	# 2. CONVECTIVE ADJUSTMENT — one thread per radial COLUMN, temp LIVE -> temp BACK.
	rd.compute_list_bind_compute_pipeline(cl, _buoy_pipe)
	rd.compute_list_bind_uniform_set(cl, _buoy_set[parity], 0)
	var buoy_pc: PackedByteArray = _buoy_pc(columns, depth)
	rd.compute_list_set_push_constant(cl, buoy_pc, buoy_pc.size())
	rd.compute_list_dispatch(cl, col_groups, 1, 1)
	rd.compute_list_add_barrier(cl)          # buoyancy output (temp BACK) committed before magma reads it

	# 3. SNAPSHOT — temp BACK -> _temp_snap, the read-IN half of magma's ping-pong.
	rd.compute_list_bind_compute_pipeline(cl, _copy_pipe)
	rd.compute_list_bind_uniform_set(cl, _snap_set[parity], 0)
	var snap_pc: PackedByteArray = _count_pc(cc)
	rd.compute_list_set_push_constant(cl, snap_pc, snap_pc.size())
	rd.compute_list_dispatch(cl, groups, 1, 1)
	rd.compute_list_add_barrier(cl)          # snapshot committed before magma gathers from it

	# 4. MAGMA — two-pass buoyant overpressure up-flow (0 = copy snapshot, 1 = gather/apply).
	rd.compute_list_bind_compute_pipeline(cl, _magma_pipe)
	rd.compute_list_bind_uniform_set(cl, _magma_set[parity], 0)
	var magma_pc0: PackedByteArray = _magma_pc(cc, 0)
	rd.compute_list_set_push_constant(cl, magma_pc0, magma_pc0.size())
	rd.compute_list_dispatch(cl, groups, 1, 1)
	rd.compute_list_add_barrier(cl)          # snapshot visible to the gather pass
	rd.compute_list_bind_compute_pipeline(cl, _magma_pipe)
	rd.compute_list_bind_uniform_set(cl, _magma_set[parity], 0)
	var magma_pc1: PackedByteArray = _magma_pc(cc, 1)
	rd.compute_list_set_push_constant(cl, magma_pc1, magma_pc1.size())
	rd.compute_list_dispatch(cl, groups, 1, 1)
	rd.compute_list_add_barrier(cl)          # committed lava/temp visible to downstream passes


## Free every RID this pass owns, dependent-first: uniform sets, then pipelines, then the private scratch
## buffers, then the shaders — before the driver drops the local RenderingDevice. `_scratch`,
## `_cond_scratch`, `_temp_snap` and `_rad_table` are created by this pass (not borrowed), so they ARE
## freed here.
func dispose(rd: RenderingDevice) -> void:
	if rd == null:
		return
	for s: Array in [_conduct_set, _copy_set, _solar_set, _buoy_set, _magma_set, _snap_set]:
		for r in s:
			if r is RID and r.is_valid():
				rd.free_rid(r)
	_conduct_set = [RID(), RID()]
	_copy_set = [RID(), RID()]
	_solar_set = [RID(), RID()]
	_buoy_set = [RID(), RID()]
	_magma_set = [RID(), RID()]
	_snap_set = [RID(), RID()]
	for r: RID in [_conduct_pipe, _copy_pipe, _solar_pipe, _buoy_pipe,
			_magma_pipe, _scratch, _cond_scratch, _temp_snap, _rad_table,
			_conduct_shader, _copy_shader, _solar_shader, _buoy_shader, _magma_shader]:
		if r.is_valid():
			rd.free_rid(r)
	_conduct_pipe = RID()
	_copy_pipe = RID()
	_solar_pipe = RID()
	_buoy_pipe = RID()
	_magma_pipe = RID()
	_scratch = RID()
	_cond_scratch = RID()
	_temp_snap = RID()
	_rad_table = RID()
	_conduct_shader = RID()
	_copy_shader = RID()
	_solar_shader = RID()
	_buoy_shader = RID()
	_magma_shader = RID()


# --- helpers ---------------------------------------------------------------------------------------------

func _load_shader(rd: RenderingDevice, path: String) -> RID:
	var sf: RDShaderFile = load(path)
	return rd.shader_create_from_spirv(sf.get_spirv())


# Build a storage-buffer uniform set from [binding, rid] pairs. Every binding the shader declares must appear.
func _make_set(rd: RenderingDevice, shader: RID, pairs: Array) -> RID:
	var uniforms: Array[RDUniform] = []
	for pair in pairs:
		var u: RDUniform = RDUniform.new()
		u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		u.binding = int(pair[0])
		u.add_id(pair[1])
		uniforms.append(u)
	return rd.uniform_set_create(uniforms, shader, 0)


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


## Real seconds one field step represents. Forwarder; the derivation lives with STEP_DT.
func _real_seconds_per_step() -> float:
	return LAMaterialFieldSphereStep3D.real_seconds_per_step()


# heat3d_buoyancy Params: { uint column_count; uint depth; uint pad0; uint pad1; } — 16 bytes.
func _buoy_pc(columns: int, depth: int) -> PackedByteArray:
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(16)
	pc.encode_u32(0, columns)
	pc.encode_u32(4, depth)
	pc.encode_u32(8, 0)
	pc.encode_u32(12, 0)
	return pc


# copy_sphere3d Params: { uint cell_count; uint pad0; uint pad1; uint pad2; } — 16 bytes.
func _count_pc(cc: int) -> PackedByteArray:
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(16)
	pc.encode_u32(0, cc)
	pc.encode_u32(4, 0)
	pc.encode_u32(8, 0)
	pc.encode_u32(12, 0)
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
