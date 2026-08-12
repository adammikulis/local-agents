extends "res://addons/local_agents/sim/material/sphere_passes/SpherePass.gd"

## Airborne dust: one conservative transport gather, dust[live] -> dust[back], with the settled share
## deposited into sediment. Dust LOFT is DEFS record M4 and runs in ReactionsPass before this pass.

const Tracer = preload("res://addons/local_agents/sim/material/sphere_passes/TracerTransport.gd")

var _transport_pipe: RID = RID()
var _transport_set: Array = [RID(), RID()]  # per parity p


func _setup(bufs: Dictionary, _cc: int) -> void:
	_transport_pipe = _kernel(Tracer.KERNEL_PATH)

	var sediment: Array = _pair(bufs, "sediment")
	var dust: Array = _pair(bufs, "dust")

	for p in 2:
		var back: int = 1 - p
		# dust[live] -> dust[back], settled share deposited into sediment.
		_transport_set[p] = _uset(_transport_pipe, Tracer.bindings(bufs, dust[p], dust[back], sediment[back]))


func dispatch(rd: RenderingDevice, cl: int, parity: int, ctx: Dictionary, cc: int, groups: int) -> void:
	if not _dispatchable():
		return
	var lat_size: float = _ctx_num(ctx, "lat_size")
	var pc: PackedByteArray = Tracer.push_constant(cc, _ctx_depth(ctx), Tracer.courant(lat_size),
			Tracer.dust_settle_v(float(ctx.get("g_m_s2", 0.0))), Tracer.EDDY_DIFFUSE, true, lat_size)
	rd.compute_list_bind_compute_pipeline(cl, _transport_pipe)
	rd.compute_list_bind_uniform_set(cl, _transport_set[parity], 0)
	rd.compute_list_set_push_constant(cl, pc, pc.size())
	rd.compute_list_dispatch(cl, groups, 1, 1)
	rd.compute_list_add_barrier(cl)          # final dust[back] + sediment deposits committed
