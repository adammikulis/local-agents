extends "res://addons/local_agents/sim/material/sphere_passes/SpherePass.gd"


const KERNEL_PATH: String = "res://addons/local_agents/sim/material/kernels3d/plate_advect_sphere3d.glsl"

var _pipe: RID = RID()
var _set_rock: Array = [RID(), RID()]   # rock_fill is SINGLE, but pass 2 binds water (a pair) → one set per parity
var _set_sed: Array = [RID(), RID()]    # sediment is a ping-pong pair — one set per parity (live half)
var _enabled: bool = true


func _setup(bufs: Dictionary, _cc: int) -> void:
	_enabled = OS.get_environment("LA_NO_PLATE_ADVECT") == ""

	_pipe = _kernel(KERNEL_PATH)

	var send_rid: RID = _single(bufs, "send")
	var radial_rid: RID = _single(bufs, "radial")
	var pos_rid: RID = _single(bufs, "pos")
	var nbr_rid: RID = _single(bufs, "nbr")
	var plates_rid: RID = _single(bufs, "plates")
	var rock_rid: RID = _single(bufs, "rock_fill")
	var sed_pair: Array = _pair(bufs, "sediment")
	if not plates_rid.is_valid() or not rock_rid.is_valid():
		push_error("PlateAdvectPass: driver did not provide the plates/rock_fill buffers")
		return

	var water_pair: Array = _pair(bufs, "water")
	for p in 2:
		_set_rock[p] = _uset(_pipe, [
			[0, rock_rid], [1, send_rid], [2, radial_rid], [3, pos_rid], [4, nbr_rid], [5, plates_rid],
			[6, water_pair[p]], [7, rock_rid]])
		_set_sed[p] = _uset(_pipe, [
			[0, sed_pair[p]], [1, send_rid], [2, radial_rid], [3, pos_rid], [4, nbr_rid], [5, plates_rid],
			[6, water_pair[p]], [7, rock_rid]])


func dispatch(rd: RenderingDevice, cl: int, parity: int, ctx: Dictionary, cc: int, groups: int) -> void:
	if not _dispatchable():
		return
	var n_plates: int = int(ctx.get("n_plates", 0)) if _enabled else 0
	# BEDROCK first, then its loose cover. Both are two dispatches (outflow, then gather) over the shared
	# `send` scratch, so the four are strictly ordered with a barrier between each.
	var rock_set: RID = _set_rock[parity]
	_carry(rd, cl, rock_set, ctx, cc, groups, n_plates)
	var sed_set: RID = _set_sed[parity]
	if sed_set.is_valid():
		_carry(rd, cl, sed_set, ctx, cc, groups, n_plates)
	# ...and then ONE displacement pass, after both mineral channels have settled, so it sees the rock where it
	# now is. Skipped when the crust is not moving: with no advection nothing newly closes over water.
	if n_plates > 0 and rock_set.is_valid():
		rd.compute_list_bind_compute_pipeline(cl, _pipe)
		rd.compute_list_bind_uniform_set(cl, rock_set, 0)
		rd.compute_list_set_push_constant(cl, _push(ctx, cc, 2, n_plates), 32)
		rd.compute_list_dispatch(cl, groups, 1, 1)
		rd.compute_list_add_barrier(cl)


# --- helpers ------------------------------------------------------------------

## One channel's transport: PASS 0 writes the outflow into `send`; barrier; PASS 1 gathers and applies in place.
func _carry(rd: RenderingDevice, cl: int, uset: RID, ctx: Dictionary, cc: int, groups: int, n_plates: int) -> void:
	if not uset.is_valid():
		return
	for pass_id in 2:
		rd.compute_list_bind_compute_pipeline(cl, _pipe)
		rd.compute_list_bind_uniform_set(cl, uset, 0)
		rd.compute_list_set_push_constant(cl, _push(ctx, cc, pass_id, n_plates), 32)
		rd.compute_list_dispatch(cl, groups, 1, 1)
		rd.compute_list_add_barrier(cl)


func _push(ctx: Dictionary, cc: int, pass_id: int, n_plates: int) -> PackedByteArray:
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(32)
	pc.encode_u32(0, cc)
	pc.encode_u32(4, pass_id)
	pc.encode_u32(8, maxi(n_plates, 0))
	pc.encode_u32(12, _ctx_depth(ctx))
	pc.encode_float(16, float(ctx.get("dt", 0.1)))
	pc.encode_float(20, _ctx_cell_size(ctx))
	pc.encode_float(24, _ctx_core_radius(ctx))
	pc.encode_float(28, float(ctx.get("max_mass", 1.0)))
	return pc
