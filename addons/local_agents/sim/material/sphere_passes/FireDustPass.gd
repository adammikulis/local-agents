extends RefCounted

## index table (cell*6 + slot; slot 0=down, 1-4=lateral, 5=up), bound at binding 15 on every kernel.

const TRANSPORT_PATH: String = "res://addons/local_agents/sim/material/kernels3d/tracer_transport_sphere3d.glsl"

# Defaults for the ctx fields (documented in the report). k (Courant factor) = dt / cell_size.
const DEFAULT_DT: float = 0.1
# Dust's still-air settling share. A PARTICULATE settles by grain size through Stokes drag, and the substrate
# could compute that — LAPhysical.GRAIN_D_UPLAND_M / GRAIN_D_LOWLAND_M carry real sieve diameters and Stokes
# Still-air settling velocity, m/s, from Stokes drag on the airborne grain size. The `dust` channel carries
# no per-cell grain diameter, so every grain settles as GRAIN_D_UPLAND_M.
static func _dust_settle_v() -> float:
	return LAPhysical.stokes_settling_velocity(LAPhysical.GRAIN_D_UPLAND_M,
			LAPhysical.AIR_DENSITY_KG_M3, LAPhysical.AIR_DYNAMIC_VISCOSITY_PA_S)
# Eddy mixing is a property of the FLOW, not of what is suspended in it, so this is the same number the gases
# use (GasWindPass.EDDY_DIFFUSE). Two tracers with two mixing rates would assert the air stirs one, not the other.
const EDDY_DIFFUSE: float = 0.02
const DEFAULT_CELL_SIZE: float = 8.0

var _transport_pipe: RID = RID()

var _transport_shader: RID = RID()

var _transport_set: Array = [RID(), RID()]  # per parity p


func setup(rd: RenderingDevice, bufs: Dictionary, _cc: int) -> void:
	# --- Pipelines --------------------------------------------------------------------------------

	var transport_sf: RDShaderFile = load(TRANSPORT_PATH)
	_transport_shader = rd.shader_create_from_spirv(transport_sf.get_spirv())
	_transport_pipe = rd.compute_pipeline_create(_transport_shader)

	# --- Shared buffers ---------------------------------------------------------------------------
	var nbr: RID = bufs["nbr"]
	var partner_rid: RID = bufs.get("link_partner", RID())
	var solid: RID = bufs["solid"]
	var vel_x: RID = bufs["vel_x"]
	var vel_y: RID = bufs["vel_y"]
	var vel_z: RID = bufs["vel_z"]
	# Per-column tangent-frame table — the wind that carries dust is stored in each cell's own frame, so both
	# dust kernels read link directions from here rather than assuming a slot is an axis.
	var ltan: RID = bufs["link_tan"]
	var shell: RID = bufs["shell"]
	var cvol: RID = bufs["cell_vol"]

	var sediment: Array = bufs["sediment"]
	var dust: Array = bufs["dust"]

	# --- Per-parity uniform sets ------------------------------------------------------------------
	for p in 2:
		var back: int = 1 - p

		_transport_set[p] = _build_set(rd, _transport_shader, [
			[0, dust[p]], [1, dust[back]], [2, sediment[back]], [3, solid],
			[4, vel_x], [5, vel_y], [6, vel_z], [15, nbr], [17, partner_rid], [16, ltan],
			[39, shell], [40, cvol]])


func dispatch(rd: RenderingDevice, cl: int, parity: int, ctx: Dictionary, cc: int, groups: int) -> void:
	# v*dt/dx in REAL units: the velocity field is m/s since the pascal migration, and one field step is
	# real_seconds_per_step() rather than the 0.1 GAME seconds ctx["dt"] carries. Dividing by a model-unit
	# cell size would be 168.6x too large.
	var dt: float = LAMaterialFieldSphereStep3D.real_seconds_per_step()
	var lat_size: float = float(ctx.get("lat_size", DEFAULT_CELL_SIZE))
	var cell_m: float = lat_size * LAPhysical.METRES_PER_MODEL_UNIT
	var k: float = dt / cell_m if cell_m != 0.0 else 0.0

	var pc_k: PackedByteArray = _pc_tracer(cc, maxi(int(ctx.get("depth", 1)), 1), k, lat_size)

	# DUST TRANSPORT — gather advect/diffuse/settle: dust[live] -> dust[back], deposit into sediment[back].
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
	for s: Array in [_transport_set]:
		for r in s:
			if r is RID and r.is_valid():
				rd.free_rid(r)
	_transport_set = [RID(), RID()]
	for r: RID in [_transport_pipe, _transport_shader]:
		if r.is_valid():
			rd.free_rid(r)
	_transport_pipe = RID()
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

func _pc_tracer(cc: int, depth: int, k: float, lat_ref: float) -> PackedByteArray:
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(36)
	pc.encode_u32(0, cc)
	pc.encode_u32(4, depth)
	pc.encode_float(8, k)
	pc.encode_float(12, _dust_settle_v())
	pc.encode_float(16, EDDY_DIFFUSE)
	pc.encode_u32(20, 1)
	pc.encode_u32(24, 0)
	pc.encode_u32(28, 0)
	pc.encode_float(32, lat_ref)
	return pc
