extends RefCounted


const KERNEL_PATH: String = "res://addons/local_agents/sim/material/kernels3d/charge_breakdown_sphere3d.glsl"

const PASS_RESET: int = 0
const PASS_SCAN: int = 1
const PASS_NEUTRALISE: int = 2

var _shader: RID = RID()
var _pipe: RID = RID()
var _sets: Array = [RID(), RID()]
var _failed_announced: bool = false


func setup(rd: RenderingDevice, bufs: Dictionary, _cc: int) -> void:
	if rd == null:
		push_error("ChargeBreakdownPass: null RenderingDevice")
		return
	for k in ["strike_idx", "strike_args", "sigma_col"]:
		if not bufs.has(k):
			push_error("ChargeBreakdownPass: driver did not allocate %s" % k)
			return
	var sf: RDShaderFile = load(KERNEL_PATH)
	if sf == null:
		push_error("ChargeBreakdownPass: charge_breakdown_sphere3d.glsl failed to load "
			+ "(run --import after editing it)")
		return
	_shader = rd.shader_create_from_spirv(sf.get_spirv())
	if not _shader.is_valid():
		push_error("ChargeBreakdownPass: shader compile failed")
		return
	_pipe = rd.compute_pipeline_create(_shader)

	for p in 2:
		var back: int = 1 - p
		_sets[p] = _build_set(rd, _shader, [
			[0, bufs["charge"]], [1, bufs["solid"]], [2, bufs["temp"][p]], [3, bufs["pos"]],
			[7, bufs["pressure"]], [43, bufs["discharge"]],
			[44, bufs["strike_idx"]], [45, bufs["strike_args"]], [46, bufs["sigma_col"]],
			[4, bufs["snow"]], [5, bufs["water"][back]], [6, bufs["rock_fill"]],
			[20, bufs["lava"][back]], [21, bufs["fuel"]], [22, bufs["biomass"]],
			[23, bufs["detritus"]], [30, bufs["sediment"][p]], [31, bufs["susp"][p]],
			[32, bufs["dust"][p]], [33, bufs["carbonate"]], [34, bufs["silica"]],
			[35, bufs["soil"][p]], [36, bufs["moisture"][p]], [37, bufs["fungus"][p]],
			[38, bufs["porosity"]], [39, bufs["shell"]]])


func dispatch(rd: RenderingDevice, cl: int, parity: int, ctx: Dictionary, cc: int, groups: int) -> void:
	if not _pipe.is_valid():
		if not _failed_announced:
			_failed_announced = true
			push_error("GPU_REQUIRED: ChargeBreakdownPass has no pipeline, so no flash can ever initiate and "
				+ "the planet's only abiotic nitrogen source is dead. Usual cause: "
				+ "charge_breakdown_sphere3d.glsl was never imported — run "
				+ "`godot --headless --path . --import` in this worktree.")
		return
	var depth: int = maxi(int(ctx.get("depth", 1)), 1)
	var columns: int = cc / depth
	var radius: float = LAPhysical.LIGHTNING_NEUTRALISED_RADIUS_M / LAPhysical.METRES_PER_MODEL_UNIT

	rd.compute_list_bind_compute_pipeline(cl, _pipe)
	rd.compute_list_bind_uniform_set(cl, _sets[parity], 0)

	var pc_reset: PackedByteArray = _pc(cc, depth, PASS_RESET, radius)
	rd.compute_list_set_push_constant(cl, pc_reset, pc_reset.size())
	rd.compute_list_dispatch(cl, 1, 1, 1)
	rd.compute_list_add_barrier(cl)

	var pc_scan: PackedByteArray = _pc(cc, depth, PASS_SCAN, radius)
	rd.compute_list_set_push_constant(cl, pc_scan, pc_scan.size())
	rd.compute_list_dispatch(cl, int(ceil(float(columns) / 64.0)), 1, 1)
	rd.compute_list_add_barrier(cl)

	var pc_neut: PackedByteArray = _pc(cc, depth, PASS_NEUTRALISE, radius)
	rd.compute_list_set_push_constant(cl, pc_neut, pc_neut.size())
	rd.compute_list_dispatch(cl, groups, 1, 1)
	rd.compute_list_add_barrier(cl)


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


# Params { uint cell_count; uint depth; uint pass_id; float radius_model; } — 16 bytes.
func _pc(cc: int, depth: int, pass_id: int, radius: float) -> PackedByteArray:
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(16)
	pc.encode_u32(0, cc)
	pc.encode_u32(4, depth)
	pc.encode_u32(8, pass_id)
	pc.encode_float(12, radius)
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
