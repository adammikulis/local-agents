extends "res://addons/local_agents/sim/material/sphere_passes/SpherePass.gd"

## Pressure at every cell: the weight of the column standing over it. One dispatch, one thread per cell.

const KERNEL_PATH: String = "res://addons/local_agents/sim/material/kernels3d/pressure.glsl"

var _pipe: RID = RID()
var _set: RID = RID()


func _setup(bufs: Dictionary, _cc: int) -> void:
	_pipe = _kernel(KERNEL_PATH)
	_set = _uset(_pipe, LABindings.set_for("pressure.glsl", bufs, {}))


func dispatch(_rd: RenderingDevice, ctx: Dictionary, cc: int, groups: int) -> void:
	if not _dispatchable() or not _set.is_valid():
		return
	_driver.run(_pipe, [_set], [_push(ctx, cc)], PackedInt32Array([groups]), [RID()],
		PackedInt32Array([0]), false, PackedStringArray([_label() + "/column"]))


func _push(ctx: Dictionary, cc: int) -> PackedByteArray:
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(12)
	pc.encode_u32(0, cc)
	pc.encode_float(4, 0.0)                       # vacuum above the outermost cell
	# A staircase up a snapped vertical takes at most one step per cell on each axis, so the walk bound is
	# the three spans and not the longest one.
	pc.encode_u32(8, 3 * int(_ctx_num(ctx, "depth")))
	return pc
