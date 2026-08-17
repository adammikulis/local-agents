extends "res://addons/local_agents/sim/material/sphere_passes/SpherePass.gd"

## Pressure at every cell: the weight of the column standing over it. One dispatch, one thread per cell.

const KERNEL_PATH: String = "res://addons/local_agents/sim/material/kernels3d/pressure.glsl"

var _pipe: RID = RID()
var _set: RID = RID()


func _setup(bufs: Dictionary, _cc: int) -> void:
	_pipe = _kernel(KERNEL_PATH)
	var missing: PackedStringArray = PackedStringArray()
	for name: String in ["pressure", "rho_bulk", "gravity", "vert_up"]:
		if not _single(bufs, name).is_valid():
			missing.append(name)
	if not missing.is_empty():
		push_error("PressurePass: no buffer for %s, so no cell would get a pressure."
			% String(", ").join(missing))
		return
	_set = _uset(_pipe, [
		[0, _single(bufs, "pressure")],
		[1, _single(bufs, "rho_bulk")],
		[3, _single(bufs, "gravity")],
		[4, _single(bufs, "vert_up")]])


func dispatch(rd: RenderingDevice, cl: int, ctx: Dictionary, cc: int, groups: int) -> void:
	if not _dispatchable() or not _set.is_valid():
		return
	rd.compute_list_bind_compute_pipeline(cl, _pipe)
	rd.compute_list_bind_uniform_set(cl, _set, 0)
	var pc: PackedByteArray = _push(ctx, cc)
	rd.compute_list_set_push_constant(cl, pc, pc.size())
	rd.compute_list_dispatch(cl, groups, 1, 1)


func _push(ctx: Dictionary, cc: int) -> PackedByteArray:
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(16)
	pc.encode_u32(0, cc)
	pc.encode_float(4, _ctx_cell_size(ctx))
	pc.encode_float(8, 0.0)                       # vacuum above the outermost cell
	# A staircase up a snapped vertical takes at most one step per cell on each axis, so the walk bound is
	# the three spans and not the longest one.
	pc.encode_u32(12, 3 * int(_ctx_num(ctx, "depth")))
	return pc
