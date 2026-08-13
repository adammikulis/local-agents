extends "res://addons/local_agents/sim/material/sphere_passes/SpherePass.gd"

## Pressure at every cell: the gas it holds, plus the condensed weight standing over it.
## Two dispatches — stamp the sentinel, then walk each column top down.

const KERNEL_PATH: String = "res://addons/local_agents/sim/material/kernels3d/pressure.glsl"

const MODE_UNWRITTEN: int = 0
const MODE_COLUMN: int = 1

var _pipe: RID = RID()
var _set: RID = RID()


func _setup(bufs: Dictionary, _cc: int) -> void:
	_pipe = _kernel(KERNEL_PATH)
	var missing: PackedStringArray = PackedStringArray()
	for name: String in ["pressure", "rho_cond", "nbr", "gravity", "n_gas_m3", "temp"]:
		if not _single(bufs, name).is_valid():
			missing.append(name)
	if not missing.is_empty():
		push_error("PressurePass: no buffer for %s, so no cell would get a pressure."
			% String(", ").join(missing))
		return
	_set = _uset(_pipe, [
		[0, _single(bufs, "pressure")],
		[1, _single(bufs, "rho_cond")],
		[2, _single(bufs, "nbr")],
		[3, _single(bufs, "gravity")],
		[4, _single(bufs, "n_gas_m3")],
		[5, _single(bufs, "temp")]])


func dispatch(rd: RenderingDevice, cl: int, _parity: int, ctx: Dictionary, cc: int, groups: int) -> void:
	if not _dispatchable() or not _set.is_valid():
		return
	rd.compute_list_bind_compute_pipeline(cl, _pipe)
	rd.compute_list_bind_uniform_set(cl, _set, 0)
	var pc: PackedByteArray = _push(ctx, cc, MODE_UNWRITTEN)
	rd.compute_list_set_push_constant(cl, pc, pc.size())
	rd.compute_list_dispatch(cl, groups, 1, 1)
	# Or the sentinel lands after the walk that replaced it.
	rd.compute_list_add_barrier(cl)
	pc = _push(ctx, cc, MODE_COLUMN)
	rd.compute_list_set_push_constant(cl, pc, pc.size())
	rd.compute_list_dispatch(cl, groups, 1, 1)


func _push(ctx: Dictionary, cc: int, mode: int) -> PackedByteArray:
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(28)
	pc.encode_u32(0, cc)
	pc.encode_float(4, _ctx_cell_size(ctx))
	pc.encode_float(8, 0.0)                       # vacuum above the outermost cell
	pc.encode_u32(12, int(_ctx_num(ctx, "depth")))
	pc.encode_float(16, LAPhysical.GAS_CONSTANT_J_MOL_K)
	pc.encode_float(20, LAPhysical.KELVIN_OFFSET)
	pc.encode_u32(24, mode)
	return pc
