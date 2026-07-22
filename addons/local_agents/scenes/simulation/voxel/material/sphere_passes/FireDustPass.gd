extends RefCounted

## Cubed-sphere FIRE + DUST pass plugin. Wires three GPU-proven sphere kernels behind the sphere GPU
## driver's pass contract (setup(rd, bufs, cc) / dispatch(rd, cl, parity, ctx, cc, groups)):
##   * fire_sphere3d.glsl          — combustion GATHER (ember spread + plume; consumes fuel/O₂, emits CO₂)
##   * dust_outscale_sphere3d.glsl — per-cell CFL out-flux scale precompute (→ dust_outscale SINGLE buffer)
##   * dust_transport_sphere3d.glsl— airborne dust advect/diffuse/settle gather + leeward deposit to sediment
## The old dust_loft_sphere3d.glsl (scour dry sediment into the cell-above's dust) is DISSOLVED into the DEFS
## reaction engine as record M4 (sediment→own-cell dust, MaterialReactions3D.gd) — a clean own-cell transfer;
## the kernel is deleted (dissolve-don't-patch). ReactionsPass runs the loft before this pass so transport
## advects the freshly lofted dust the same step.
##
## The driver owns the ping-pong `bufs` dictionary and the compute list. This plugin only builds pipelines +
## per-parity uniform sets in setup(), then records bind/push/dispatch/barrier into the driver's `cl` in
## dispatch(). Parity roles mirror the verified box orchestrator (MaterialGPU3D.gd) so behaviour matches:
## a PAIR channel's "live" role binds bufs[key][parity] and its "back" role binds bufs[key][1-parity].
##
## bufs contract (from the driver): PAIR key → [rid_a, rid_b]; SINGLE key → rid. `nbr` is a SINGLE int32
## index table (cell*6 + slot; slot 0=down, 1-4=lateral, 5=up), bound at binding 15 on every kernel.

const FIRE_PATH: String = "res://addons/local_agents/scenes/simulation/voxel/material/kernels3d/fire_sphere3d.glsl"
const OUTSCALE_PATH: String = "res://addons/local_agents/scenes/simulation/voxel/material/kernels3d/dust_outscale_sphere3d.glsl"
const TRANSPORT_PATH: String = "res://addons/local_agents/scenes/simulation/voxel/material/kernels3d/dust_transport_sphere3d.glsl"

# Defaults for the ctx fields (documented in the report). k (Courant factor) = dt / cell_size.
const DEFAULT_DT: float = 0.1
const DEFAULT_CELL_SIZE: float = 8.0

var _fire_pipe: RID = RID()
var _outscale_pipe: RID = RID()
var _transport_pipe: RID = RID()

var _fire_shader: RID = RID()
var _outscale_shader: RID = RID()
var _transport_shader: RID = RID()

var _fire_set: Array = [RID(), RID()]       # per parity p
var _transport_set: Array = [RID(), RID()]  # per parity p
var _outscale_set: RID = RID()              # parity-independent (only SINGLE buffers) → one set


func setup(rd: RenderingDevice, bufs: Dictionary, _cc: int) -> void:
	# --- Pipelines --------------------------------------------------------------------------------
	var fire_sf: RDShaderFile = load(FIRE_PATH)
	_fire_shader = rd.shader_create_from_spirv(fire_sf.get_spirv())
	_fire_pipe = rd.compute_pipeline_create(_fire_shader)

	var outscale_sf: RDShaderFile = load(OUTSCALE_PATH)
	_outscale_shader = rd.shader_create_from_spirv(outscale_sf.get_spirv())
	_outscale_pipe = rd.compute_pipeline_create(_outscale_shader)

	var transport_sf: RDShaderFile = load(TRANSPORT_PATH)
	_transport_shader = rd.shader_create_from_spirv(transport_sf.get_spirv())
	_transport_pipe = rd.compute_pipeline_create(_transport_shader)

	# --- Shared buffers ---------------------------------------------------------------------------
	var nbr: RID = bufs["nbr"]
	var fuel: RID = bufs["fuel"]
	var solid: RID = bufs["solid"]
	var vel_x: RID = bufs["vel_x"]
	var vel_y: RID = bufs["vel_y"]
	var vel_z: RID = bufs["vel_z"]
	var outscale: RID = bufs["dust_outscale"]

	var fire: Array = bufs["fire"]
	var temp: Array = bufs["temp"]
	var water: Array = bufs["water"]
	var o2: Array = bufs["o2"]
	var co2: Array = bufs["co2"]
	var sediment: Array = bufs["sediment"]
	var dust: Array = bufs["dust"]
	var activity: Array = bufs["activity"]

	# --- Per-parity uniform sets ------------------------------------------------------------------
	for p in 2:
		var back: int = 1 - p

		# fire_sphere3d.glsl — 0 fire_in(live), 1 fire_out(back), 2 fuel(single), 3 temp(back, in place),
		# 4 water(back), 5 solid(single), 6 o2(BACK, in place), 7 co2(BACK, in place), 8 activity(BACK,
		# Keystone-C wake gate — ActivityPass runs just before this pass and writes activity[back] this same
		# step), 15 nbr.
		# o2/co2 must mutate the BACK half: GasWind wrote its transport result into o2/co2[back] earlier this
		# step, and the authoritative readback reads _live() = the back half AFTER the phase flip — so combustion
		# must consume O2 / emit CO2 into [back] or its writes are silently discarded (fire wouldn't affect gas).
		_fire_set[p] = _build_set(rd, _fire_shader, [
			[0, fire[p]], [1, fire[back]], [2, fuel], [3, temp[back]],
			[4, water[back]], [5, solid], [6, o2[back]], [7, co2[back]], [8, activity[back]], [15, nbr]])

		# dust_transport_sphere3d.glsl — 0 dust_in(live), 1 dust_out(back), 2 sediment(back, in place +=
		# deposit), 3 outscale(single), 4 vel_x, 5 vel_y, 6 vel_z, 7 solid, 15 nbr.
		_transport_set[p] = _build_set(rd, _transport_shader, [
			[0, dust[p]], [1, dust[back]], [2, sediment[back]], [3, outscale],
			[4, vel_x], [5, vel_y], [6, vel_z], [7, solid], [15, nbr]])

	# dust_outscale_sphere3d.glsl — 0 outscale(out, single), 1 vel_x, 2 vel_y, 3 vel_z, 4 solid, 15 nbr.
	# No PAIR buffers → parity-independent, one set reused for both parities.
	_outscale_set = _build_set(rd, _outscale_shader, [
		[0, outscale], [1, vel_x], [2, vel_y], [3, vel_z], [4, solid], [15, nbr]])


func dispatch(rd: RenderingDevice, cl: int, parity: int, ctx: Dictionary, cc: int, groups: int) -> void:
	var dt: float = float(ctx.get("dt", DEFAULT_DT))
	var cell_size: float = float(ctx.get("cell_size", DEFAULT_CELL_SIZE))
	var k: float = dt / cell_size if cell_size != 0.0 else 0.0

	var pc_fire: PackedByteArray = _pc_count(cc)
	var pc_k: PackedByteArray = _pc_count_k(cc, k)

	# 1) FIRE — combustion gather: fire[live] -> fire[back]; temp/fuel/o2/co2 mutated in place.
	rd.compute_list_bind_compute_pipeline(cl, _fire_pipe)
	rd.compute_list_bind_uniform_set(cl, _fire_set[parity], 0)
	rd.compute_list_set_push_constant(cl, pc_fire, pc_fire.size())
	rd.compute_list_dispatch(cl, groups, 1, 1)
	rd.compute_list_add_barrier(cl)

	# 2) DUST OUTSCALE — precompute per-cell CFL out-flux scale into the dust_outscale SINGLE buffer.
	rd.compute_list_bind_compute_pipeline(cl, _outscale_pipe)
	rd.compute_list_bind_uniform_set(cl, _outscale_set, 0)
	rd.compute_list_set_push_constant(cl, pc_k, pc_k.size())
	rd.compute_list_dispatch(cl, groups, 1, 1)
	rd.compute_list_add_barrier(cl)          # out-flux scale visible to the transport gather

	# 3) DUST TRANSPORT — gather advect/diffuse/settle: dust[live] -> dust[back], deposit into sediment[back].
	rd.compute_list_bind_compute_pipeline(cl, _transport_pipe)
	rd.compute_list_bind_uniform_set(cl, _transport_set[parity], 0)
	rd.compute_list_set_push_constant(cl, pc_k, pc_k.size())
	rd.compute_list_dispatch(cl, groups, 1, 1)
	rd.compute_list_add_barrier(cl)          # final dust[back] + sediment deposits committed
	# (dust LOFT is now DEFS record M4, run in ReactionsPass before this pass — kernel deleted.)


## Free every RID this pass owns (uniform sets, then pipelines, then shaders), dependent-first, before the
## driver drops the local RenderingDevice. This pass owns no scratch buffers (all bindings are borrowed bufs).
func dispose(rd: RenderingDevice) -> void:
	if rd == null:
		return
	for s: Array in [_fire_set, _transport_set]:
		for r in s:
			if r is RID and r.is_valid():
				rd.free_rid(r)
	_fire_set = [RID(), RID()]
	_transport_set = [RID(), RID()]
	if _outscale_set.is_valid():
		rd.free_rid(_outscale_set)
		_outscale_set = RID()
	for r: RID in [_fire_pipe, _outscale_pipe, _transport_pipe,
			_fire_shader, _outscale_shader, _transport_shader]:
		if r.is_valid():
			rd.free_rid(r)
	_fire_pipe = RID()
	_outscale_pipe = RID()
	_transport_pipe = RID()
	_fire_shader = RID()
	_outscale_shader = RID()
	_transport_shader = RID()


# --- helpers --------------------------------------------------------------------------------------

func _build_set(rd: RenderingDevice, shader: RID, entries: Array) -> RID:
	var uniforms: Array = []
	for e in entries:
		uniforms.append(_u(int(e[0]), e[1]))
	return rd.uniform_set_create(uniforms, shader, 0)

func _u(binding: int, buf: RID) -> RDUniform:
	var u: RDUniform = RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u.binding = binding
	u.add_id(buf)
	return u

# fire push: { uint cell_count; uint pad0,pad1,pad2; }
func _pc_count(cc: int) -> PackedByteArray:
	return PackedInt32Array([cc, 0, 0, 0]).to_byte_array()

# dust_outscale / dust_transport push: { uint cell_count; float k; float pad0,pad1; }
func _pc_count_k(cc: int, k: float) -> PackedByteArray:
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(16)
	pc.encode_u32(0, cc)
	pc.encode_float(4, k)
	return pc
