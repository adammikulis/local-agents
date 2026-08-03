extends RefCounted

## Cubed-sphere ACTIVE-CELL COMPACTION pass. Runs cell_list_lava_sphere3d.glsl to build the compacted index
## list + dispatch-indirect argument that ThermalPass's lava_phase leg consumes, turning that kernel from one
## invocation per GRID cell into one invocation per ACTIVE cell.
##
## THE SELECTION IS PHYSICAL — a cell is listed because it HOLDS MOLTEN ROCK IN OPEN SPACE. This pass used to
## AND that with a camera-relevance stride gate, which made which lava cooled depend on where the player was
## standing; that mechanism is deleted (see MaterialSphereGPU3D.gd's header note). What is left is the part
## that was always right: an O(active) compaction keyed on what the matter is doing.
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
## between here and lava_phase writes either, so the list cannot go stale.
##
## WHAT MAKES THE ARGS VISIBLE TO ThermalPass: Godot's RenderingDeviceGraph, which tracks buffer
## dependencies and inserts barriers automatically. NOT the driver's full_barrier() call — that is
## DEPRECATED AND A NO-OP in Godot 4.7, and it warns 8855 times in a 150-frame run saying so
## ("Barriers are automatically inserted by RenderingDevice"). An earlier version of this comment
## credited full_barrier(), which matters because this is the comment the next pass conversion is told
## to copy: someone would have preserved a no-op believing it was load-bearing.
##
## EXTENDING IT TO ANOTHER KERNEL. Two conditions, both hard. (1) The kernel's skip path must be a bare
## `return` — a compacted dispatch simply never runs the un-listed cells, so any kernel that WRITES on its skip
## path would leave those writes undone. lava_phase qualifies; several other kernels do not (a ping-pong
## channel whose back half must be carried needs that carry hoisted somewhere that still covers every cell, or
## the channel made single-buffered and in-place, before this is legal for it). (2) The predicate must be
## PHYSICAL and read only inputs that are already final at this point in the pass order — what the matter is
## doing, never what the camera can see. A predicate that depends on the viewer is not an optimisation, it is
## a change to the simulation.
##
## Kernel binding -> bufs-key map (authoritative layout is cell_list_lava_sphere3d.glsl):
##   1 Lava=lava[back] · 2 Solid=solid · 4 ActiveIdx=active_idx · 5 ActiveArgs=active_args

const KERNEL_PATH: String = "res://addons/local_agents/sim/material/kernels3d/cell_list_lava_sphere3d.glsl"

const PASS_RESET: int = 0
const PASS_APPEND: int = 1
const PASS_ARGS: int = 2

var _shader: RID = RID()
var _pipe: RID = RID()
var _sets: Array = [RID(), RID()]       # one uniform set per ping-pong parity
var _failed_announced: bool = false     # so the GPU_REQUIRED error below fires once, not 60x a second


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
	var active_idx: RID = bufs["active_idx"]
	var active_args: RID = bufs["active_args"]
	var lava: Array = bufs["lava"]

	for p in 2:
		var back: int = 1 - p
		_sets[p] = _build_set(rd, _shader, [
			[1, lava[back]],        # Lava — BACK half (post lava_flow), exactly what lava_phase reads
			[2, solid],
			[4, active_idx],
			[5, active_args]])


func dispatch(rd: RenderingDevice, cl: int, parity: int, ctx: Dictionary, cc: int, groups: int) -> void:
	# FAIL LOUDLY, ONCE. If setup() failed, this pass no-ops, `active_args` stays all-zero, and ThermalPass's
	# dispatch_indirect then runs ZERO workgroups — lava_phase is completely dead while the sim keeps running
	# and SIM_REPORT keeps printing normal-looking numbers. That is precisely the silent-degradation the repo
	# forbids on an authoritative path, and it is reachable by the documented fresh-worktree trap (a .glsl that
	# was never imported makes load() return null). The cheapest honest guard is to say so unmissably rather
	# than let a run look healthy: one error, not one per frame, because 60 Hz of push_error buries the log
	# that would explain it.
	if not _pipe.is_valid():
		if not _failed_announced:
			_failed_announced = true
			push_error("GPU_REQUIRED: LavaCellListPass has no pipeline, so lava_phase will process ZERO cells "
				+ "and molten rock will neither cool nor solidify. Any lava/rock result from this run is void. "
				+ "Usual cause: cell_list_lava_sphere3d.glsl was never imported — run "
				+ "`godot --headless --path . --import` in this worktree.")
		return
	rd.compute_list_bind_compute_pipeline(cl, _pipe)
	rd.compute_list_bind_uniform_set(cl, _sets[parity], 0)

	# 0. RESET the counter (one thread; the other 63 return immediately).
	var pc_reset: PackedByteArray = _pc(cc, PASS_RESET)
	rd.compute_list_set_push_constant(cl, pc_reset, pc_reset.size())
	rd.compute_list_dispatch(cl, 1, 1, 1)
	rd.compute_list_add_barrier(cl)

	# 1. APPEND — the one remaining full-grid dispatch.
	var pc_append: PackedByteArray = _pc(cc, PASS_APPEND)
	rd.compute_list_set_push_constant(cl, pc_append, pc_append.size())
	rd.compute_list_dispatch(cl, groups, 1, 1)
	rd.compute_list_add_barrier(cl)

	# 2. ARGS — publish groups_x = ceil(count / 64) for the consumer's indirect dispatch.
	var pc_args: PackedByteArray = _pc(cc, PASS_ARGS)
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

# Params { uint cell_count; uint pass_id; uint pad0; uint pad1; } — 16 bytes.
func _pc(cc: int, pass_id: int) -> PackedByteArray:
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(16)
	pc.encode_u32(0, cc)
	pc.encode_u32(4, pass_id)
	pc.encode_u32(8, 0)
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
