extends "res://addons/local_agents/sim/material/sphere_passes/SpherePass.gd"

## Advects the suspended mineral load on the flowing water, carrying its enthalpy with it: outflow into the
## shared `send` scratch, then a volume-corrected gather back into susp.

const KERNEL_PATH: String = "res://addons/local_agents/sim/material/kernels3d/erosion_transport_sphere3d.glsl"

## Channels rc_shared.glsli reads, with the binding each arrives on. The half is the one settled where this
## pass sits in the dispatch order: BACK for a producer that has already run this step, LIVE for one that
## has not.
const RC_BACK_BINDS: Dictionary = {"water": 7, "lava": 20, "sediment": 30, "soil": 35, "moisture": 36}
const RC_LIVE_BINDS: Dictionary = {"susp": 31, "dust": 32, "fungus": 37}
const RC_SINGLE_BINDS: Dictionary = {"rock_fill": 18, "snow": 19, "fuel": 21, "biomass": 22,
	"detritus": 23, "carbonate": 33, "silica": 34, "porosity": 38}

var _pipe: RID = RID()
var _set: Array = [RID(), RID()]        # one uniform set per ping-pong parity
## Enthalpy scratch, one slot per cell face: pass 0 writes it, pass 1 gathers it. A receiver cannot read its
## donor's temperature instead — pass 1 writes temp, so that read races the write.
var _send_h: RID = RID()


func _setup(bufs: Dictionary, cc: int) -> void:
	_pipe = _kernel(KERNEL_PATH)
	_send_h = _scratch(cc * 6)

	var solid_rid: RID = _single(bufs, "solid")
	var send_rid: RID = _single(bufs, "send")
	var nbr_rid: RID = _single(bufs, "nbr")
	var partner_rid: RID = _single(bufs, "link_partner")
	var cvol_rid: RID = _single(bufs, "cell_vol")
	var water_pair: Array = _pair(bufs, "water")
	var susp_pair: Array = _pair(bufs, "susp")
	var temp_pair: Array = _pair(bufs, "temp")

	for p in 2:
		var back: int = 1 - p
		var entries: Array = [
			[0, susp_pair[p]],       # SuspIn  = live susp
			[1, susp_pair[back]],    # SuspOut = back susp (fully written)
			[2, water_pair[p]],      # FlowHead = LIVE half: the pre-step head the water CA flowed on
			[3, solid_rid],          # Solid
			[4, _send_h],            # SendH — paired slot-for-slot with Send
			[5, send_rid],           # Shared outflow scratch (self-zeroed by pass 0)
			[6, temp_pair[back]],    # Temp = POST-thermal temp (BACK, rw)
			[15, nbr_rid],           # Neigh table
			[17, partner_rid],       # the slot that answers each link
			[40, cvol_rid],          # per-cell volume, model units^3
		]
		for name: String in RC_BACK_BINDS:
			entries.append([int(RC_BACK_BINDS[name]), _half(bufs, name, p, true)])
		for name: String in RC_LIVE_BINDS:
			entries.append([int(RC_LIVE_BINDS[name]), _half(bufs, name, p, false)])
		for name: String in RC_SINGLE_BINDS:
			entries.append([int(RC_SINGLE_BINDS[name]), _single(bufs, name)])
		_set[p] = _uset(_pipe, entries)


func dispatch(rd: RenderingDevice, cl: int, parity: int, _ctx: Dictionary, cc: int, groups: int) -> void:
	if not _dispatchable():
		return
	# PASS 0 — outflow into `send`; barrier; PASS 1 — inflow/apply into susp[back].
	for pass_id in 2:
		rd.compute_list_bind_compute_pipeline(cl, _pipe)
		rd.compute_list_bind_uniform_set(cl, _set[parity], 0)
		var pc: PackedByteArray = PackedInt32Array([cc, pass_id, 0, 0]).to_byte_array()
		rd.compute_list_set_push_constant(cl, pc, pc.size())
		rd.compute_list_dispatch(cl, groups, 1, 1)
		rd.compute_list_add_barrier(cl)
