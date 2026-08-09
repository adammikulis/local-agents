extends RefCounted

## Cubed-sphere DUST pass plugin. Wires two GPU-proven sphere kernels behind the sphere GPU driver's pass
## contract (setup(rd, bufs, cc) / dispatch(rd, cl, parity, ctx, cc, groups)):
##   * dust_outscale_sphere3d.glsl:  per-cell CFL out-flux scale precompute (→ dust_outscale SINGLE buffer)
##   * dust_transport_sphere3d.glsl: airborne dust advect/diffuse/settle gather + leeward deposit to sediment
##
## THE FIRE IS GONE FROM IT, 2026-08-09, and so is fire_sphere3d.glsl. Combustion is a reaction record now —
## `reactions/CombustionRecords.gd` R26, an ARRHENIUS rate on cellulose's measured pyrolysis activation
## energy — so the kernel this pass was named after, together with IGNITE_TEMP (one global ignition
## temperature for every combustible cell on the planet), FIRE_START, FIRE_MIN, FIRE_GROW, the stored `fire`
## intensity channel and a bespoke radiant-spread gather, is deleted rather than ported. Flame spread is the
## heat the reaction releases, carried by the thermal kernels that already exist; there is no spread code.
## THE FILE KEEPS ITS NAME on purpose: renaming it means editing LAMaterialSphereGPU3D.PASS_SCRIPTS, which
## other tracks are editing concurrently. The rename is owed and is cosmetic.
##
## The old dust_loft_sphere3d.glsl (scour dry sediment into the cell-above's dust) is DISSOLVED into the DEFS
## reaction engine as record M4 (sediment→own-cell dust, MaterialReactions3D.gd), a clean own-cell transfer;
## the kernel is deleted (dissolve-don't-patch). ReactionsPass runs the loft before this pass so transport
## advects the freshly lofted dust the same step.
##
## The driver owns the ping-pong `bufs` dictionary and the compute list. This plugin only builds pipelines +
## per-parity uniform sets in setup(), then records bind/push/dispatch/barrier into the driver's `cl` in
## dispatch(). The parity convention is stated here because this pass is now where it lives: a PAIR channel's
## "live" role binds bufs[key][parity] and its "back" role binds bufs[key][1-parity].
## *(Corrected 2026-08-09. This used to read "Parity roles mirror the verified box orchestrator
## (MaterialGPU3D.gd) so behaviour matches". MaterialGPU3D.gd was deleted with the box stack and is nowhere in
## this tree, so "mirrors the verified X" pointed at nothing verifiable — and it named a deleted file as the
## reason to trust a convention, which is exactly backwards.)*
##
## bufs contract (from the driver): PAIR key → [rid_a, rid_b]; SINGLE key → rid. `nbr` is a SINGLE int32
## index table (cell*6 + slot; slot 0=down, 1-4=lateral, 5=up), bound at binding 15 on every kernel.

const OUTSCALE_PATH: String = "res://addons/local_agents/sim/material/kernels3d/dust_outscale_sphere3d.glsl"
const TRANSPORT_PATH: String = "res://addons/local_agents/sim/material/kernels3d/dust_transport_sphere3d.glsl"

# Defaults for the ctx fields (documented in the report). k (Courant factor) = dt / cell_size.
const DEFAULT_DT: float = 0.1
const DEFAULT_CELL_SIZE: float = 8.0

var _outscale_pipe: RID = RID()
var _transport_pipe: RID = RID()

var _outscale_shader: RID = RID()
var _transport_shader: RID = RID()

var _transport_set: Array = [RID(), RID()]  # per parity p
var _outscale_set: Array = [RID(), RID()]   # per parity p (both identical — it binds no PAIR channel)


func setup(rd: RenderingDevice, bufs: Dictionary, _cc: int) -> void:
	# --- Pipelines --------------------------------------------------------------------------------
	var outscale_sf: RDShaderFile = load(OUTSCALE_PATH)
	_outscale_shader = rd.shader_create_from_spirv(outscale_sf.get_spirv())
	_outscale_pipe = rd.compute_pipeline_create(_outscale_shader)

	var transport_sf: RDShaderFile = load(TRANSPORT_PATH)
	_transport_shader = rd.shader_create_from_spirv(transport_sf.get_spirv())
	_transport_pipe = rd.compute_pipeline_create(_transport_shader)

	# --- Shared buffers ---------------------------------------------------------------------------
	var nbr: RID = bufs["nbr"]
	var solid: RID = bufs["solid"]
	var vel_x: RID = bufs["vel_x"]
	var vel_y: RID = bufs["vel_y"]
	var vel_z: RID = bufs["vel_z"]
	var outscale: RID = bufs["dust_outscale"]
	# Per-column tangent-frame table — the wind that carries dust is stored in each cell's own frame, so both
	# dust kernels read link directions from here rather than assuming a slot is an axis.
	var ltan: RID = bufs["link_tan"]

	var sediment: Array = bufs["sediment"]
	var dust: Array = bufs["dust"]

	# --- Per-parity uniform sets ------------------------------------------------------------------
	for p in 2:
		var back: int = 1 - p

		# dust_transport_sphere3d.glsl — 0 dust_in(live), 1 dust_out(back), 2 sediment(back, in place +=
		# deposit), 3 outscale(single), 4 vel_x, 5 vel_y, 6 vel_z, 7 solid, 15 nbr, 16 link_tan.
		_transport_set[p] = _build_set(rd, _transport_shader, [
			[0, dust[p]], [1, dust[back]], [2, sediment[back]], [3, outscale],
			[4, vel_x], [5, vel_y], [6, vel_z], [7, solid], [15, nbr], [16, ltan]])

		# dust_outscale_sphere3d.glsl — 0 outscale(out, single), 1 vel_x, 2 vel_y, 3 vel_z, 4 solid,
		# 15 nbr, 16 link_tan. Every buffer it binds is parity-independent, so both entries are the same set;
		# kept per-parity only so dispatch() can index it exactly like the other two.
		_outscale_set[p] = _build_set(rd, _outscale_shader, [
			[0, outscale], [1, vel_x], [2, vel_y], [3, vel_z], [4, solid],
			[15, nbr], [16, ltan]])


func dispatch(rd: RenderingDevice, cl: int, parity: int, ctx: Dictionary, cc: int, groups: int) -> void:
	var dt: float = float(ctx.get("dt", DEFAULT_DT))
	var cell_size: float = float(ctx.get("cell_size", DEFAULT_CELL_SIZE))
	var k: float = dt / cell_size if cell_size != 0.0 else 0.0

	var pc_k: PackedByteArray = _pc_count_k(cc, k, maxi(int(ctx.get("depth", 1)), 1))

	# 1) DUST OUTSCALE — precompute per-cell CFL out-flux scale into the dust_outscale SINGLE buffer.
	rd.compute_list_bind_compute_pipeline(cl, _outscale_pipe)
	rd.compute_list_bind_uniform_set(cl, _outscale_set[parity], 0)
	rd.compute_list_set_push_constant(cl, pc_k, pc_k.size())
	rd.compute_list_dispatch(cl, groups, 1, 1)
	rd.compute_list_add_barrier(cl)          # out-flux scale visible to the transport gather

	# 2) DUST TRANSPORT — gather advect/diffuse/settle: dust[live] -> dust[back], deposit into sediment[back].
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
	for s: Array in [_transport_set, _outscale_set]:
		for r in s:
			if r is RID and r.is_valid():
				rd.free_rid(r)
	_transport_set = [RID(), RID()]
	_outscale_set = [RID(), RID()]
	for r: RID in [_outscale_pipe, _transport_pipe, _outscale_shader, _transport_shader]:
		if r.is_valid():
			rd.free_rid(r)
	_outscale_pipe = RID()
	_transport_pipe = RID()
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

# dust_outscale / dust_transport push: { uint cell_count; float k; uint pad0; uint depth; }
# `depth` turns a cell index into its radial COLUMN, which is how the per-column link-direction table is indexed.
func _pc_count_k(cc: int, k: float, depth: int) -> PackedByteArray:
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(16)
	pc.encode_u32(0, cc)
	pc.encode_float(4, k)
	pc.encode_u32(8, 0)
	pc.encode_u32(12, depth)
	return pc
