class_name LASphereThermalPass
extends RefCounted

## CUBED-SPHERE thermal-forcing GPU pass plugin. Wires the five per-cell sphere heat/lava kernels that run
## AFTER conduction + the water/lava flow gathers, mirroring the box orchestrator's post-conduction heat tail
## (LAMaterialGPU3D solar->buoyancy->cooling, then the lava_phase + magma_buoy geological cores). It owns only
## its pipelines, per-parity uniform sets and one private lava-snapshot scratch buffer; every field SSBO is
## handed in via `bufs` and every per-frame scalar via `ctx`.
##
## KERNELS + ORDER (recorded into the caller's compute list, in this exact sequence):
##   1. heat3d_solar_sphere3d   — THE TERMINATOR. Per-cell insolation = max(0, dot(cell_radial, sun_dir)) at
##                                sky-exposed surface cells; heat-IN-PLACE on temp + solid + radial(14) + nbr(15).
##   2. heat3d_buoyancy_sphere3d — hot void rises radially outward. RACE-FREE double-buffered GATHER
##                                (TempIn -> TempOut) + solid + nbr(15).
##   3. heat3d_cool_sphere3d     — evaporative/marine cooling of wet cells toward the sea thermocline; IN-PLACE
##                                on temp, reads post-flow water + solid + per-cell world Pos(3, vec4) + lava(4)
##                                and a sea_radius push param. A wet cell carrying lava QUENCHES hard (the
##                                submerged-lava heat sink that lets a seabed vent build an island).
##   4. lava_phase_sphere3d      — solidify (freeze cold lava to rock) + sustain (keep remaining lava molten);
##                                IN-PLACE on lava + temp + solid, no neighbour reads.
##   5. magma_buoy_sphere3d      — buoyant overpressure up-flow, TWO passes (0 = copy snapshot, 1 =
##                                gather/apply) with a barrier between; lava + private scratch + temp + solid +
##                                nbr(15).
##
## PARITY / PING-PONG CONTRACT (READ THIS before wiring the orchestrator):
##   `parity` p selects the live buffer for every PAIR channel: live = bufs[key][p], back = bufs[key][1 - p].
##   Because the sphere buoyancy is a GATHER (unlike the box's in-place column sweep), it is the single flip in
##   this pass. To keep the downstream in-place kernels (cool/lava_phase/magma) reading the buoyancy OUTPUT while
##   still binding the BACK buffer (matching the box's role labels), the chain is arranged as:
##     - solar     : IN-PLACE on temp LIVE[p]   (runs first, feeds the buoyancy gather)
##     - buoyancy  : temp LIVE[p] (TempIn) -> temp BACK[1-p] (TempOut)   (fresh temp now in BACK)
##     - cool      : IN-PLACE on temp BACK[1-p], reads water BACK[1-p]   (post-flow water)
##     - lava_phase: IN-PLACE on lava BACK[1-p] + temp BACK[1-p]
##     - magma     : lava BACK[1-p] + temp BACK[1-p] + private scratch
##   ENTRY expectation: fresh temp in LIVE[p]; fresh water + lava already in BACK[1-p] (their flow gathers ran
##   earlier this frame). EXIT state: fresh temp AND lava both in BACK[1-p] — consistent with the box's
##   post-heat convention (downstream wind/atmosphere read temp_back) and a single end-of-step parity flip.

const CONDUCT_PATH: String = "res://addons/local_agents/scenes/simulation/voxel/material/kernels3d/heat_sphere3d.glsl"
const COPY_PATH: String = "res://addons/local_agents/scenes/simulation/voxel/material/kernels3d/copy_sphere3d.glsl"
const SOLAR_PATH: String = "res://addons/local_agents/scenes/simulation/voxel/material/kernels3d/heat3d_solar_sphere3d.glsl"
const BUOY_PATH: String = "res://addons/local_agents/scenes/simulation/voxel/material/kernels3d/heat3d_buoyancy_sphere3d.glsl"
const COOL_PATH: String = "res://addons/local_agents/scenes/simulation/voxel/material/kernels3d/heat3d_cool_sphere3d.glsl"
const LAVA_PHASE_PATH: String = "res://addons/local_agents/scenes/simulation/voxel/material/kernels3d/lava_phase_sphere3d.glsl"
const MAGMA_PATH: String = "res://addons/local_agents/scenes/simulation/voxel/material/kernels3d/magma_buoy_sphere3d.glsl"

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
var _cool_shader: RID = RID()
var _lava_phase_shader: RID = RID()
var _magma_shader: RID = RID()

var _solar_pipe: RID = RID()
var _buoy_pipe: RID = RID()
var _cool_pipe: RID = RID()
var _lava_phase_pipe: RID = RID()
var _magma_pipe: RID = RID()

# Per-parity uniform sets (index = parity p).
var _solar_set: Array = [RID(), RID()]
var _buoy_set: Array = [RID(), RID()]
var _cool_set: Array = [RID(), RID()]
var _lava_phase_set: Array = [RID(), RID()]
var _magma_set: Array = [RID(), RID()]

# Private stable-snapshot scratch for the magma two-pass gather (cc floats). Never handed in via bufs — a
# lava_phase/magma-only working buffer, exactly like the box's _buf_lava_scratch.
var _scratch: RID = RID()


func setup(rd: RenderingDevice, bufs: Dictionary, cc: int) -> void:
	_cc = cc

	_solar_shader = _load_shader(rd, SOLAR_PATH)
	_solar_pipe = rd.compute_pipeline_create(_solar_shader)
	_buoy_shader = _load_shader(rd, BUOY_PATH)
	_buoy_pipe = rd.compute_pipeline_create(_buoy_shader)
	_cool_shader = _load_shader(rd, COOL_PATH)
	_cool_pipe = rd.compute_pipeline_create(_cool_shader)
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

	for p in 2:
		var back: int = 1 - p
		var temp_live: RID = temp[p]
		var temp_back: RID = temp[back]
		var water_back: RID = water[back]
		var lava_back: RID = lava[back]

		# conduct (heat_sphere3d): 0 = TempIn (LIVE), 1 = TempOut (scratch), 2 = nbr, 3 = solid (per-bond rock vs
		# void conductivity — the crust insulates the hot core). copy: 0 = scratch, 1 = temp LIVE.
		_conduct_set[p] = _make_set(rd, _conduct_shader, [
			[0, temp_live], [1, _cond_scratch], [2, nbr], [3, solid]])
		_copy_set[p] = _make_set(rd, _copy_shader, [
			[0, _cond_scratch], [1, temp_live]])
		# solar: 0 = temp (LIVE, in-place), 1 = solid, 3 = pos (flat float3, altitude lapse), 14 = radial, 15 = nbr.
		_solar_set[p] = _make_set(rd, _solar_shader, [
			[0, temp_live], [1, solid], [3, pos], [14, radial], [15, nbr]])
		# buoyancy: 0 = TempIn (LIVE), 1 = TempOut (BACK), 2 = solid, 15 = nbr.
		_buoy_set[p] = _make_set(rd, _buoy_shader, [
			[0, temp_live], [1, temp_back], [2, solid], [15, nbr]])
		# cool: 0 = temp (BACK, in-place), 1 = water (BACK, post-flow), 2 = solid, 3 = pos (vec4), 4 = lava (BACK,
		# post-flow) — a wet cell carrying lava quenches HARD (submerged-lava sink; builds the seabed island).
		_cool_set[p] = _make_set(rd, _cool_shader, [
			[0, temp_back], [1, water_back], [2, solid], [3, pos], [4, lava_back]])
		# lava_phase: 0 = lava (BACK, in-place), 1 = temp (BACK, in-place), 2 = solid.
		_lava_phase_set[p] = _make_set(rd, _lava_phase_shader, [
			[0, lava_back], [1, temp_back], [2, solid]])
		# magma: 0 = lava (BACK, rw), 1 = scratch (private), 2 = temp (BACK, carry-heat), 3 = solid, 15 = nbr.
		_magma_set[p] = _make_set(rd, _magma_shader, [
			[0, lava_back], [1, _scratch], [2, temp_back], [3, solid], [15, nbr]])


func dispatch(rd: RenderingDevice, cl: int, parity: int, ctx: Dictionary, cc: int, groups: int) -> void:
	var sun_dir: Vector3 = ctx.get("sun_dir", Vector3(0.0, 1.0, 0.0))
	var sea_radius: float = ctx.get("sea_radius", 248.0)

	# 0. CONDUCTION — relax temp toward its 6-neighbour mean (net-zero-flip: gather LIVE->scratch, copy back).
	# This is the ONLY lateral/radial heat conduction in the field; it carries the pinned magma core outward to
	# the surface (geothermal gradient) and smooths solar/buoyancy forcing. Runs through rock AND void.
	var cond_pc: PackedByteArray = _count_pc(cc)
	rd.compute_list_bind_compute_pipeline(cl, _conduct_pipe)
	rd.compute_list_bind_uniform_set(cl, _conduct_set[parity], 0)
	rd.compute_list_set_push_constant(cl, cond_pc, cond_pc.size())
	rd.compute_list_dispatch(cl, groups, 1, 1)
	rd.compute_list_add_barrier(cl)          # conducted temp (scratch) visible to the copy-back
	rd.compute_list_bind_compute_pipeline(cl, _copy_pipe)
	rd.compute_list_bind_uniform_set(cl, _copy_set[parity], 0)
	rd.compute_list_set_push_constant(cl, cond_pc, cond_pc.size())
	rd.compute_list_dispatch(cl, groups, 1, 1)
	rd.compute_list_add_barrier(cl)          # temp LIVE now carries conduction, feeds solar

	# 1. SOLAR — the terminator, in-place on temp LIVE.
	rd.compute_list_bind_compute_pipeline(cl, _solar_pipe)
	rd.compute_list_bind_uniform_set(cl, _solar_set[parity], 0)
	var solar_pc: PackedByteArray = _solar_pc(cc, sun_dir, sea_radius)
	rd.compute_list_set_push_constant(cl, solar_pc, solar_pc.size())
	rd.compute_list_dispatch(cl, groups, 1, 1)
	rd.compute_list_add_barrier(cl)          # solar output (temp LIVE) visible to the buoyancy gather

	# 2. BUOYANCY — gather temp LIVE -> temp BACK.
	rd.compute_list_bind_compute_pipeline(cl, _buoy_pipe)
	rd.compute_list_bind_uniform_set(cl, _buoy_set[parity], 0)
	var buoy_pc: PackedByteArray = _count_pc(cc)
	rd.compute_list_set_push_constant(cl, buoy_pc, buoy_pc.size())
	rd.compute_list_dispatch(cl, groups, 1, 1)
	rd.compute_list_add_barrier(cl)          # buoyancy output (temp BACK) visible to cooling

	# 3. COOL — evaporative/marine cooling, in-place on temp BACK.
	rd.compute_list_bind_compute_pipeline(cl, _cool_pipe)
	rd.compute_list_bind_uniform_set(cl, _cool_set[parity], 0)
	var cool_pc: PackedByteArray = _cool_pc(cc, sea_radius)
	rd.compute_list_set_push_constant(cl, cool_pc, cool_pc.size())
	rd.compute_list_dispatch(cl, groups, 1, 1)
	rd.compute_list_add_barrier(cl)          # post-heat temp committed before the lava passes read it

	# 4. LAVA PHASE — solidify + sustain, in-place on lava BACK + temp BACK.
	rd.compute_list_bind_compute_pipeline(cl, _lava_phase_pipe)
	rd.compute_list_bind_uniform_set(cl, _lava_phase_set[parity], 0)
	var phase_pc: PackedByteArray = _count_pc(cc)
	rd.compute_list_set_push_constant(cl, phase_pc, phase_pc.size())
	rd.compute_list_dispatch(cl, groups, 1, 1)
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
			_cool_set, _lava_phase_set, _magma_set]:
		for r in s:
			if r is RID and r.is_valid():
				rd.free_rid(r)
	_conduct_set = [RID(), RID()]
	_copy_set = [RID(), RID()]
	_solar_set = [RID(), RID()]
	_buoy_set = [RID(), RID()]
	_cool_set = [RID(), RID()]
	_lava_phase_set = [RID(), RID()]
	_magma_set = [RID(), RID()]
	for r: RID in [_conduct_pipe, _copy_pipe, _solar_pipe, _buoy_pipe, _cool_pipe,
			_lava_phase_pipe, _magma_pipe, _scratch, _cond_scratch,
			_conduct_shader, _copy_shader, _solar_shader, _buoy_shader, _cool_shader,
			_lava_phase_shader, _magma_shader]:
		if r.is_valid():
			rd.free_rid(r)
	_conduct_pipe = RID()
	_copy_pipe = RID()
	_solar_pipe = RID()
	_buoy_pipe = RID()
	_cool_pipe = RID()
	_lava_phase_pipe = RID()
	_magma_pipe = RID()
	_scratch = RID()
	_cond_scratch = RID()
	_conduct_shader = RID()
	_copy_shader = RID()
	_solar_shader = RID()
	_buoy_shader = RID()
	_cool_shader = RID()
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


# heat3d_solar Params: { uint cell_count; uint pad0; uint pad1; uint pad2; float sun_x; float sun_y;
#   float sun_z; float sea_radius; } — 32 bytes. sun_dir at offset 16; sea_radius (altitude-lapse datum) at 28.
func _solar_pc(cc: int, sun_dir: Vector3, sea_radius: float) -> PackedByteArray:
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(32)
	pc.encode_u32(0, cc)
	pc.encode_u32(4, 0)
	pc.encode_u32(8, 0)
	pc.encode_u32(12, 0)
	pc.encode_float(16, sun_dir.x)
	pc.encode_float(20, sun_dir.y)
	pc.encode_float(24, sun_dir.z)
	pc.encode_float(28, sea_radius)
	return pc


# heat3d_cool Params: { uint cell_count; float sea_radius; float pad0; float pad1; } — 16 bytes.
func _cool_pc(cc: int, sea_radius: float) -> PackedByteArray:
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(16)
	pc.encode_u32(0, cc)
	pc.encode_float(4, sea_radius)
	pc.encode_float(8, 0.0)
	pc.encode_float(12, 0.0)
	return pc


# heat3d_buoyancy / lava_phase Params: { uint cell_count; uint pad0; uint pad1; uint pad2; } — 16 bytes.
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
