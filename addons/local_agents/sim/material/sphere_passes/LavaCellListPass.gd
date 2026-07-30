extends RefCounted

## Cubed-sphere ACTIVE-CELL COMPACTION pass (Keystone C, asymptotic half). Runs cell_list_lava_sphere3d.glsl
## to build the compacted index list + dispatch-indirect argument that ThermalPass's lava_phase leg consumes,
## turning that kernel from one invocation per GRID cell into one invocation per ACTIVE cell.
##
## THE SHAPE, so the next pass to be converted can copy it. Three dispatches into the caller's compute list,
## barrier-separated, all from ONE pipeline selected by a `pass_id` push constant:
##   0. RESET  — one thread zeroes the counters and writes the constant groups_y/groups_z of the indirect arg.
##   1. APPEND — full grid, workgroup-aggregated atomic append of every cell that passes the predicate.
##   2. ARGS   — one thread turns the final count into groups_x = ceil(count / 64).
## The consumer then binds `active_idx` + `active_args` and calls compute_list_dispatch_indirect(cl, args, 0)
## instead of compute_list_dispatch(cl, groups, 1, 1). The APPEND pass is the only full-grid dispatch left, and
## it reads 4 floats per cell rather than the consumer's full input set, so the trade is a cheap uniform scan
## for a dispatch that scales with the phenomenon instead of the planet.
##
## PLACEMENT (MaterialSphereGPU3D.PASS_SCRIPTS): between WaterSlumpLavaPass and ThermalPass. It needs
## lava[back] final (WaterSlumpLava's lava_flow leg writes it) and `solid` final (SolidDerivePass), and nothing
## between here and lava_phase writes either, so the list cannot go stale. `relevance` is activity[LIVE] —
## the same half, and therefore the same documented one-step lag, that lava_phase read for itself before this
## pass existed. The driver's inter-pass full_barrier() is what makes the args visible to ThermalPass.
##
## EXTENDING IT TO THE OTHER PASSES. The predicate is exact only because every branch it stands in for is a
## bare `return` in the consumer (see the kernel header). The other relevance-gated kernels all WRITE on their
## skip path — fire persists fire_out=fire_in, erosion carries susp live->back, dust_outscale writes 0.0,
## charge_accum applies its quiet leak, soil zeroes send[] — so a compacted dispatch would leave those writes
## undone. Converting one of them means first hoisting its skip-path write somewhere that still covers every
## cell: either make the channel single-buffered and in-place (no carry needed at all), or give the driver a
## per-channel ping-pong phase so an unwritten back half is simply not flipped to. Both are real changes to the
## driver's buffer contract, not to this mechanism, which is why this slice converts the one kernel that
## already needs neither.
##
## Kernel binding -> bufs-key map (authoritative layout is cell_list_lava_sphere3d.glsl):
##   0 Relevance=activity[live] · 1 Lava=lava[back] · 2 Solid=solid · 3 Static=static ·
##   4 ActiveIdx=active_idx · 5 ActiveArgs=active_args

const KERNEL_PATH: String = "res://addons/local_agents/sim/material/kernels3d/cell_list_lava_sphere3d.glsl"

const PASS_RESET: int = 0
const PASS_APPEND: int = 1
const PASS_ARGS: int = 2

var _shader: RID = RID()
var _pipe: RID = RID()
var _sets: Array = [RID(), RID()]       # one uniform set per ping-pong parity


func setup(rd: RenderingDevice, bufs: Dictionary, _cc: int) -> void:
	if rd == null:
		push_error("LavaCellListPass: null RenderingDevice")
		return
	if not bufs.has("active_idx") or not bufs.has("active_args"):
		push_error("LavaCellListPass: driver did not allocate active_idx/active_args")
		return

	var sf: RDShaderFile = load(KERNEL_PATH)
	if sf == null:
		push_error("LavaCellListPass: cell_list_lava_sphere3d.glsl failed to load (run --import after editing it)")
		return
	_shader = rd.shader_create_from_spirv(sf.get_spirv())
	if not _shader.is_valid():
		push_error("LavaCellListPass: shader compile failed")
		return
	_pipe = rd.compute_pipeline_create(_shader)

	var solid: RID = bufs["solid"]
	var static_ch: RID = bufs["static"]
	var active_idx: RID = bufs["active_idx"]
	var active_args: RID = bufs["active_args"]
	var lava: Array = bufs["lava"]
	var activity: Array = bufs["activity"]

	for p in 2:
		var back: int = 1 - p
		_sets[p] = _build_set(rd, _shader, [
			[0, activity[p]],       # Relevance — LIVE half (this pass runs before ActivityPass)
			[1, lava[back]],        # Lava — BACK half (post lava_flow), exactly what lava_phase reads
			[2, solid],
			[3, static_ch],
			[4, active_idx],
			[5, active_args]])


func dispatch(rd: RenderingDevice, cl: int, parity: int, ctx: Dictionary, cc: int, groups: int) -> void:
	if not _pipe.is_valid():
		return
	var step_index: int = int(ctx.get("step_index", 0))
	rd.compute_list_bind_compute_pipeline(cl, _pipe)
	rd.compute_list_bind_uniform_set(cl, _sets[parity], 0)

	# 0. RESET the counters (one thread; the other 63 return immediately).
	var pc_reset: PackedByteArray = _pc(cc, step_index, PASS_RESET)
	rd.compute_list_set_push_constant(cl, pc_reset, pc_reset.size())
	rd.compute_list_dispatch(cl, 1, 1, 1)
	rd.compute_list_add_barrier(cl)

	# 1. APPEND — the one remaining full-grid dispatch.
	var pc_append: PackedByteArray = _pc(cc, step_index, PASS_APPEND)
	rd.compute_list_set_push_constant(cl, pc_append, pc_append.size())
	rd.compute_list_dispatch(cl, groups, 1, 1)
	rd.compute_list_add_barrier(cl)

	# 2. ARGS — publish groups_x = ceil(count / 64) for the consumer's indirect dispatch.
	var pc_args: PackedByteArray = _pc(cc, step_index, PASS_ARGS)
	rd.compute_list_set_push_constant(cl, pc_args, pc_args.size())
	rd.compute_list_dispatch(cl, 1, 1, 1)


## Free every RID this pass owns (uniform sets, pipeline, shader). `active_idx`/`active_args` are borrowed
## from the driver's `bufs` and are freed there, not here — same convention as every other pass module.
func dispose(rd: RenderingDevice) -> void:
	if rd == null:
		return
	for r: RID in _sets:
		if r is RID and r.is_valid():
			rd.free_rid(r)
	_sets = [RID(), RID()]
	if _pipe.is_valid():
		rd.free_rid(_pipe)
		_pipe = RID()
	if _shader.is_valid():
		rd.free_rid(_shader)
		_shader = RID()


# --- helpers ---------------------------------------------------------------------------------------------

# Params { uint cell_count; uint step_index; uint pass_id; uint pad0; } — 16 bytes.
func _pc(cc: int, step_index: int, pass_id: int) -> PackedByteArray:
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(16)
	pc.encode_u32(0, cc)
	pc.encode_u32(4, step_index)
	pc.encode_u32(8, pass_id)
	pc.encode_u32(12, 0)
	return pc


func _build_set(rd: RenderingDevice, shader: RID, entries: Array) -> RID:
	var uniforms: Array = []
	for e in entries:
		var u: RDUniform = RDUniform.new()
		u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		u.binding = int(e[0])
		u.add_id(e[1])
		uniforms.append(u)
	return rd.uniform_set_create(uniforms, shader, 0)
