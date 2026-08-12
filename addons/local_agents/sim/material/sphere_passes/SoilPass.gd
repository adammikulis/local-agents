extends "res://addons/local_agents/sim/material/sphere_passes/SpherePass.gd"

## Groundwater: Darcy flow between regolith cells, springs into open cells, infiltration from the surface.
## Every transfer writes its enthalpy into `_send_h` beside its own `send` slot.

const SOIL_PATH: String = "res://addons/local_agents/sim/material/kernels3d/soil_sphere3d.glsl"

## Channels rc_shared.glsli reads that this kernel does not already bind, with the binding each arrives on.
## The half is the one settled where SoilPass sits in the dispatch order: BACK for a producer that has run
## this step, LIVE for one that has not.
const RC_BACK_BINDS: Dictionary = {"lava": 20, "sediment": 30, "susp": 31, "moisture": 36}
const RC_LIVE_BINDS: Dictionary = {"dust": 32, "fungus": 37}
const RC_SINGLE_BINDS: Dictionary = {"rock_fill": 18, "snow": 19, "fuel": 21, "biomass": 22,
	"detritus": 23, "carbonate": 33, "silica": 34}

var _pipe: RID = RID()
var _set: Array = [RID(), RID()]        # one uniform set per parity p in [0, 1]
## Enthalpy scratch, one slot per cell face: pass 0 writes it, pass 1 gathers it. A receiver cannot read its
## donor's temperature instead — pass 1 writes temp, so that read races the write.
var _send_h: RID = RID()


func _setup(bufs: Dictionary, cc: int) -> void:
	_pipe = _kernel(SOIL_PATH)
	_send_h = _scratch(cc * 6)

	var b: Dictionary = _rids(bufs,
		["solid", "send", "nbr", "link_partner", "shell", "cell_vol", "regolith", "grain",
			"soil_dbg", "porosity"],
		["water", "soil", "temp"])

	for p in 2:
		var back: int = 1 - p
		var entries: Array = [
			[0, b["water"][back]],     # Water  = settled back water (read-modify-write)
			[1, b["solid"]],
			[2, _send_h],              # SendH — paired slot-for-slot with Send
			[3, b["send"]],            # Send scratch
			[4, b["soil"][p]],         # SoilIn  = live soil (last step's output)
			[5, b["soil"][back]],      # SoilOut = back soil (this step's output)
			[6, b["regolith"]],        # Regolith aquifer permeability mask
			[7, b["temp"][back]],      # Temp = POST-thermal temp (BACK, rw)
			[8, b["grain"]],           # Grain diameter, m
			[9, b["soil_dbg"]],        # SoilDbg — per-leg budget probe
			[11, b["porosity"]],       # Porosity — phi
			[15, b["nbr"]],            # Neigh table
			[17, b["link_partner"]],   # the slot that answers each link
			[39, b["shell"]],          # radial shell table, model units
			[40, b["cell_vol"]],       # per-cell volume, model units^3
		]
		for name: String in RC_BACK_BINDS:
			entries.append([int(RC_BACK_BINDS[name]), _half(bufs, name, p, true)])
		for name: String in RC_LIVE_BINDS:
			entries.append([int(RC_LIVE_BINDS[name]), _half(bufs, name, p, false)])
		for name: String in RC_SINGLE_BINDS:
			entries.append([int(RC_SINGLE_BINDS[name]), _single(bufs, name)])
		_set[p] = _uset(_pipe, entries)


func dispatch(rd: RenderingDevice, cl: int, parity: int, ctx: Dictionary, cc: int, groups: int) -> void:
	if not _dispatchable():
		return
	var uset: RID = _set[parity]
	var depth: int = _ctx_depth(ctx)
	var lat_size: float = _ctx_num(ctx, "lat_size")
	# PASS 0 — compute groundwater/infiltration/exfiltration transfers into `send`; PASS 1 — apply.
	for pass_id in 2:
		rd.compute_list_bind_compute_pipeline(cl, _pipe)
		rd.compute_list_bind_uniform_set(cl, uset, 0)
		var pc: PackedByteArray = _pc(cc, pass_id, depth, lat_size)
		rd.compute_list_set_push_constant(cl, pc, pc.size())
		rd.compute_list_dispatch(cl, groups, 1, 1)
		rd.compute_list_add_barrier(cl)


## std430: 4x uint (cell_count, pass_id, depth, pad) then 3x float (lat_size, shell_m, step_s).
func _pc(cc: int, pass_id: int, depth: int, lat_size: float) -> PackedByteArray:
	var out: PackedByteArray = PackedInt32Array([cc, pass_id, depth, 0]).to_byte_array()
	out.append_array(PackedFloat32Array([lat_size,
		LAMaterialFieldRegolith3D.shell_metres(),
		LAMaterialFieldSphereStep3D.real_seconds_per_step()]).to_byte_array())
	return out
