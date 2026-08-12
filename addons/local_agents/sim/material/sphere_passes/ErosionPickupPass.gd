extends "res://addons/local_agents/sim/material/sphere_passes/SpherePass.gd"

## Scours bedrock mineral into the suspended load where flowing water has the shear to lift it.

const KERNEL_PATH: String = "res://addons/local_agents/sim/material/kernels3d/erosion_pickup_sphere3d.glsl"

## Channels rc_shared.glsli reads that this kernel does not already bind, with the binding each arrives on.
## The half is the one settled where this pass sits in the dispatch order.
const RC_BACK_BINDS: Dictionary = {"lava": 20, "sediment": 30, "soil": 35, "moisture": 36}
const RC_LIVE_BINDS: Dictionary = {"dust": 32, "fungus": 37}
const RC_SINGLE_BINDS: Dictionary = {"snow": 19, "fuel": 21, "biomass": 22, "detritus": 23,
	"carbonate": 33, "silica": 34, "porosity": 38}

var _pipe: RID = RID()
var _set: Array = [RID(), RID()]        # one uniform set per ping-pong parity


func _setup(bufs: Dictionary, _cc: int) -> void:
	_pipe = _kernel(KERNEL_PATH)

	var solid_rid: RID = _single(bufs, "solid")
	var rock_rid: RID = _single(bufs, "rock_fill")
	var nbr_rid: RID = _single(bufs, "nbr")
	var cvol_rid: RID = _single(bufs, "cell_vol")
	var water_pair: Array = _pair(bufs, "water")
	var susp_pair: Array = _pair(bufs, "susp")
	var temp_pair: Array = _pair(bufs, "temp")

	for p in 2:
		var back: int = 1 - p
		# Read the SETTLED water (back half, matching ReactionsPass) and ADD the scour to the back susp that
		# ErosionTransportPass has just filled with the advected load.
		var entries: Array = [
			[0, water_pair[back]],   # Water = settled water (back)
			[1, solid_rid],          # Solid
			[2, temp_pair[back]],    # Temp = POST-thermal temp (BACK, rw)
			[3, rock_rid],           # RockFill (SINGLE, scoured in place)
			[4, susp_pair[back]],    # Susp = back susp (advected load; += scour, own-cell)
			[15, nbr_rid],           # Neigh table
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
	rd.compute_list_bind_compute_pipeline(cl, _pipe)
	rd.compute_list_bind_uniform_set(cl, _set[parity], 0)
	var pc: PackedByteArray = _pc_cells(cc)
	rd.compute_list_set_push_constant(cl, pc, pc.size())
	rd.compute_list_dispatch(cl, groups, 1, 1)
