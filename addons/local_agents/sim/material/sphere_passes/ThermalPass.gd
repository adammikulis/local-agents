class_name LASphereThermalPass
extends RefCounted


const CONDUCT_PATH: String = "res://addons/local_agents/sim/material/kernels3d/heat_sphere3d.glsl"
const COPY_PATH: String = "res://addons/local_agents/sim/material/kernels3d/copy_sphere3d.glsl"
const SOLAR_PATH: String = "res://addons/local_agents/sim/material/kernels3d/heat3d_solar_sphere3d.glsl"
const BUOY_PATH: String = "res://addons/local_agents/sim/material/kernels3d/heat3d_buoyancy_sphere3d.glsl"
const LAVA_PHASE_PATH: String = "res://addons/local_agents/sim/material/kernels3d/lava_phase_sphere3d.glsl"
const MAGMA_PATH: String = "res://addons/local_agents/sim/material/kernels3d/magma_buoy_sphere3d.glsl"

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
var _lava_phase_shader: RID = RID()
var _magma_shader: RID = RID()

var _solar_pipe: RID = RID()
var _buoy_pipe: RID = RID()
var _lava_phase_pipe: RID = RID()
var _magma_pipe: RID = RID()

# Per-parity uniform sets (index = parity p).
var _solar_set: Array = [RID(), RID()]
var _buoy_set: Array = [RID(), RID()]
var _lava_phase_set: Array = [RID(), RID()]
var _magma_set: Array = [RID(), RID()]

# Private stable-snapshot scratch for the magma two-pass gather (cc floats). Never handed in via bufs — a
# lava_phase/magma-only working buffer, exactly like the box's _buf_lava_scratch.
var _scratch: RID = RID()

# BORROWED (owned by the driver, freed there — NOT in dispose below): the dispatch-indirect argument buffer
# LavaCellListPass publishes each step. Held as a field because dispatch() needs the RID, and it is the same
# buffer for both parities.
var _active_args: RID = RID()


func setup(rd: RenderingDevice, bufs: Dictionary, cc: int) -> void:
	_cc = cc

	_solar_shader = _load_shader(rd, SOLAR_PATH)
	_solar_pipe = rd.compute_pipeline_create(_solar_shader)
	_buoy_shader = _load_shader(rd, BUOY_PATH)
	_buoy_pipe = rd.compute_pipeline_create(_buoy_shader)
	_lava_phase_shader = _load_shader(rd, LAVA_PHASE_PATH)
	_lava_phase_pipe = rd.compute_pipeline_create(_lava_phase_shader)
	_magma_shader = _load_shader(rd, MAGMA_PATH)
	_magma_pipe = rd.compute_pipeline_create(_magma_shader)
	_conduct_shader = _load_shader(rd, CONDUCT_PATH)
	_conduct_pipe = rd.compute_pipeline_create(_conduct_shader)
	_copy_shader = _load_shader(rd, COPY_PATH)
	_copy_pipe = rd.compute_pipeline_create(_copy_shader)

	# Private magma snapshot scratch + conduction gather scratch (cc float32, zero-initialised).
	var zf: PackedFloat32Array = PackedFloat32Array()
	zf.resize(cc)
	var zb: PackedByteArray = zf.to_byte_array()
	_scratch = rd.storage_buffer_create(zb.size(), zb)
	_cond_scratch = rd.storage_buffer_create(zb.size(), zb)

	var solid: RID = bufs["solid"]
	var nbr: RID = bufs["nbr"]
	var radial: RID = bufs["radial"]
	var pos: RID = bufs["pos"]
	var temp: Array = bufs["temp"]
	var water: Array = bufs["water"]
	var lava: Array = bufs["lava"]
	# Compacted active-cell list for the lava_phase leg (built by LavaCellListPass earlier in the same step).
	var active_idx: RID = bufs["active_idx"]
	var active_args: RID = bufs["active_args"]
	var shell: RID = bufs["shell"]
	_active_args = active_args

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
		# solar: 0 = temp (LIVE, in-place), 1 = solid, 3 = pos (flat float3), 14 = radial, 15 = nbr.
		_solar_set[p] = _make_set(rd, _solar_shader, [
			[0, temp_live], [1, solid], [3, pos],
			[4, bufs["snow"]], [5, water_back], [6, bufs["rock_fill"]], [7, bufs["pressure"]],
			[8, _cond_scratch], [14, radial], [15, nbr], [39, shell], [27, bufs["biomass"]],
			# 20/21/23 = lava / fuel / detritus for rc_shared.glsli (biomass is already bound at 27 for albedo).
			[20, lava_back], [21, bufs["fuel"]], [23, bufs["detritus"]]]
			+ shared_carriers)
		# buoyancy: 0 = TempIn (LIVE), 1 = TempOut (BACK), 2 = solid, the material mix 4 = snow, 5 = water,
		# 6 = rock_fill (it convects an ENERGY flux and divides by each side's own capacity), 15 = nbr.
		_buoy_set[p] = _make_set(rd, _buoy_shader, [
			[0, temp_live], [1, temp_back], [2, solid],
			[4, bufs["snow"]], [5, water_back], [6, bufs["rock_fill"]], [15, nbr],
			# 20-23 = the carriers rc_shared.glsli needs; this kernel reads none of them itself.
			[20, lava_back], [21, bufs["fuel"]], [22, bufs["biomass"]], [23, bufs["detritus"]]]
			+ shared_carriers)
		# lava_phase: 0 = lava (BACK, in-place), 1 = temp (BACK, in-place), 2 = solid, 4 = the compacted
		# sea floor cooled as if it were surrounded by air instead of by the 4.17e6 J/m3K of the ocean.
		_lava_phase_set[p] = _make_set(rd, _lava_phase_shader, [
			[0, lava_back], [1, temp_back], [2, solid],
			[4, active_idx], [5, active_args], [15, nbr], [39, shell],
			[6, bufs["rock_fill"]], [7, water_back], [21, bufs["fuel"]], [22, bufs["biomass"]],
			[23, bufs["detritus"]], [24, bufs["snow"]]]
			+ shared_carriers)
		# magma: 0 = lava (BACK, rw), 1 = scratch (private), 2 = temp (BACK, carry-heat), 3 = solid, 15 = nbr.
		_magma_set[p] = _make_set(rd, _magma_shader, [
			[0, lava_back], [1, _scratch], [2, temp_back], [3, solid], [15, nbr]])


func dispatch(rd: RenderingDevice, cl: int, parity: int, ctx: Dictionary, cc: int, groups: int) -> void:
	var sun_dir: Vector3 = ctx.get("sun_dir", Vector3(0.0, 1.0, 0.0))
	var sea_radius: float = float(ctx.get("sea_radius", 0.0))
	var depth: int = maxi(int(ctx.get("depth", 1)), 1)
	var lat_dx: float = float(ctx.get("lat_size", 0.0))
	var core_boundary_c: float = float(ctx.get("core_boundary_c", 0.0))

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
	rd.compute_list_add_barrier(cl)          # temp LIVE now carries conduction, feeds solar

	# 1. SOLAR — the terminator, in-place on temp LIVE.
	rd.compute_list_bind_compute_pipeline(cl, _solar_pipe)
	rd.compute_list_bind_uniform_set(cl, _solar_set[parity], 0)
	var solar_pc: PackedByteArray = _solar_pc(cc, sun_dir, sea_radius, _real_seconds_per_step(), depth)
	rd.compute_list_set_push_constant(cl, solar_pc, solar_pc.size())
	rd.compute_list_dispatch(cl, groups, 1, 1)
	rd.compute_list_add_barrier(cl)          # solar output (temp LIVE) visible to the buoyancy gather

	# 2. BUOYANCY — gather temp LIVE -> temp BACK.
	rd.compute_list_bind_compute_pipeline(cl, _buoy_pipe)
	rd.compute_list_bind_uniform_set(cl, _buoy_set[parity], 0)
	var buoy_pc: PackedByteArray = _count_pc(cc)
	rd.compute_list_set_push_constant(cl, buoy_pc, buoy_pc.size())
	rd.compute_list_dispatch(cl, groups, 1, 1)
	rd.compute_list_add_barrier(cl)          # buoyancy output (temp BACK) committed before the lava passes read it


	rd.compute_list_bind_compute_pipeline(cl, _lava_phase_pipe)
	rd.compute_list_bind_uniform_set(cl, _lava_phase_set[parity], 0)
	var phase_pc: PackedByteArray = _lava_phase_pc(cc, _real_seconds_per_step(), depth)
	rd.compute_list_set_push_constant(cl, phase_pc, phase_pc.size())
	rd.compute_list_dispatch_indirect(cl, _active_args, 0)
	rd.compute_list_add_barrier(cl)          # post-phase lava/temp visible to the magma snapshot

	# 5. MAGMA — two-pass buoyant overpressure up-flow (0 = copy snapshot, 1 = gather/apply).
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
## buffers, then the shaders — before the driver drops the local RenderingDevice. `_scratch` and
## `_cond_scratch` are created by this pass (not borrowed), so they ARE freed here.
func dispose(rd: RenderingDevice) -> void:
	if rd == null:
		return
	for s: Array in [_conduct_set, _copy_set, _solar_set, _buoy_set,
			_lava_phase_set, _magma_set]:
		for r in s:
			if r is RID and r.is_valid():
				rd.free_rid(r)
	_conduct_set = [RID(), RID()]
	_copy_set = [RID(), RID()]
	_solar_set = [RID(), RID()]
	_buoy_set = [RID(), RID()]
	_lava_phase_set = [RID(), RID()]
	_magma_set = [RID(), RID()]
	for r: RID in [_conduct_pipe, _copy_pipe, _solar_pipe, _buoy_pipe,
			_lava_phase_pipe, _magma_pipe, _scratch, _cond_scratch,
			_conduct_shader, _copy_shader, _solar_shader, _buoy_shader,
			_lava_phase_shader, _magma_shader]:
		if r.is_valid():
			rd.free_rid(r)
	_conduct_pipe = RID()
	_copy_pipe = RID()
	_solar_pipe = RID()
	_buoy_pipe = RID()
	_lava_phase_pipe = RID()
	_magma_pipe = RID()
	_scratch = RID()
	_cond_scratch = RID()
	_conduct_shader = RID()
	_copy_shader = RID()
	_solar_shader = RID()
	_buoy_shader = RID()
	_lava_phase_shader = RID()
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


func _solar_pc(cc: int, sun_dir: Vector3, sea_radius: float, dt_s: float, depth: int) -> PackedByteArray:
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(32)
	pc.encode_u32(0, cc)
	pc.encode_float(4, dt_s)
	pc.encode_u32(8, depth)
	pc.encode_u32(12, 0)
	pc.encode_float(16, sun_dir.x)
	pc.encode_float(20, sun_dir.y)
	pc.encode_float(24, sun_dir.z)
	pc.encode_float(28, sea_radius)
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


## Real seconds one field step represents. EVERY kernel in this pass now runs on it — conduction, the
## of 432 apart inside one energy budget. The derivation lives with STEP_DT; this is a forwarder.
func _real_seconds_per_step() -> float:
	return LAMaterialFieldSphereStep3D.real_seconds_per_step()


# heat3d_buoyancy Params: { uint cell_count; uint pad0; uint pad1; uint pad2; } — 16 bytes.
func _count_pc(cc: int) -> PackedByteArray:
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(16)
	pc.encode_u32(0, cc)
	pc.encode_u32(4, 0)
	pc.encode_u32(8, 0)
	pc.encode_u32(12, 0)
	return pc


# exposed faces, which is a FLUX in W/m^2, so turning it into a temperature needs the step's real seconds and
func _lava_phase_pc(cc: int, dt_s: float, depth: int) -> PackedByteArray:
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(16)
	pc.encode_u32(0, cc)
	pc.encode_float(4, dt_s)
	pc.encode_u32(8, depth)
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
