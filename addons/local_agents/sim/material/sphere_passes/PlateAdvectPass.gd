extends "res://addons/local_agents/sim/material/sphere_passes/SpherePass.gd"

## Carries bedrock and its loose cover with the plate that holds them, then evicts the fluid the arriving
## rock displaced. Every transfer moves its enthalpy with it.

const KERNEL_PATH: String = "res://addons/local_agents/sim/material/kernels3d/plate_advect_sphere3d.glsl"

## Channels rc_shared.glsli reads that this kernel does not already bind, with the binding each arrives on.
## This pass runs first in the step, so every pair is read at its LIVE half.
const RC_PAIR_BINDS: Dictionary = {"lava": 20, "sediment": 30, "susp": 31, "dust": 32, "soil": 35,
	"moisture": 36, "fungus": 37}
const RC_SINGLE_BINDS: Dictionary = {"snow": 19, "fuel": 21, "biomass": 22, "detritus": 23,
	"carbonate": 33, "silica": 34, "porosity": 38}

var _pipe: RID = RID()
var _set_rock: Array = [RID(), RID()]   # rock_fill is SINGLE, but the fluid passes bind water (a pair)
var _set_sed: Array = [RID(), RID()]    # sediment is a ping-pong pair — one set per parity (live half)
## Enthalpy scratch, one slot per cell face: the send passes write it, the apply passes gather it. A receiver
## cannot read its donor's temperature instead — the apply pass writes temp, so that read races it.
var _send_h: RID = RID()


func _setup(bufs: Dictionary, cc: int) -> void:
	_pipe = _kernel(KERNEL_PATH)
	_send_h = _scratch(cc * 6)

	var send_rid: RID = _single(bufs, "send")
	var radial_rid: RID = _single(bufs, "radial")
	var pos_rid: RID = _single(bufs, "pos")
	var nbr_rid: RID = _single(bufs, "nbr")
	var partner_rid: RID = _single(bufs, "link_partner")
	var shell_rid: RID = _single(bufs, "shell")
	var cvol_rid: RID = _single(bufs, "cell_vol")
	var plates_rid: RID = _single(bufs, "plates")
	var rock_rid: RID = _single(bufs, "rock_fill")
	var sed_pair: Array = _pair(bufs, "sediment")
	var water_pair: Array = _pair(bufs, "water")
	var temp_pair: Array = _pair(bufs, "temp")
	if not plates_rid.is_valid() or not rock_rid.is_valid():
		push_error("PlateAdvectPass: driver did not provide the plates/rock_fill buffers")
		return

	for p in 2:
		var shared: Array = [
			[1, send_rid],           # Send scratch
			[2, radial_rid],         # outward unit vector, c*3+{0,1,2}
			[3, pos_rid],            # world position, c*3+{0,1,2}
			[4, nbr_rid],            # Neigh table
			[5, plates_rid],         # plate kinematics, 8 floats per plate
			[6, water_pair[p]],      # the fluid the rock evicts
			[7, rock_rid],           # RockFill
			[8, _send_h],            # SendH — paired slot-for-slot with Send
			[9, temp_pair[p]],       # Temp, in place
			[17, partner_rid],       # the slot that answers each link
			[39, shell_rid],         # radial shell table, model units
			[40, cvol_rid],          # per-cell volume, model units^3
		]
		for name: String in RC_PAIR_BINDS:
			shared.append([int(RC_PAIR_BINDS[name]), _half(bufs, name, p, false)])
		for name: String in RC_SINGLE_BINDS:
			shared.append([int(RC_SINGLE_BINDS[name]), _single(bufs, name)])
		_set_rock[p] = _uset(_pipe, [[0, rock_rid]] + shared)
		_set_sed[p] = _uset(_pipe, [[0, sed_pair[p]]] + shared)


func dispatch(rd: RenderingDevice, cl: int, parity: int, ctx: Dictionary, cc: int, groups: int) -> void:
	if not _dispatchable():
		return
	var n_plates: int = int(ctx.get("n_plates", 0))
	# BEDROCK first, then its loose cover. Each is two dispatches (outflow, then gather) over the shared
	# `send` scratch, so they are strictly ordered with a barrier between each.
	var rock_set: RID = _set_rock[parity]
	_carry(rd, cl, rock_set, ctx, cc, groups, n_plates, true)
	var sed_set: RID = _set_sed[parity]
	_carry(rd, cl, sed_set, ctx, cc, groups, n_plates, false)
	# ...then the displacement, after both mineral channels have settled, so it sees the rock where it now
	# is: pass 2 sends the evicted fluid outward, pass 3 lands it. With no advection nothing newly closes
	# over water, so both are skipped.
	if n_plates > 0 and rock_set.is_valid():
		for pass_id in [2, 3]:
			rd.compute_list_bind_compute_pipeline(cl, _pipe)
			rd.compute_list_bind_uniform_set(cl, rock_set, 0)
			var pc: PackedByteArray = _push(ctx, cc, pass_id, n_plates, false)
			rd.compute_list_set_push_constant(cl, pc, pc.size())
			rd.compute_list_dispatch(cl, groups, 1, 1)
			rd.compute_list_add_barrier(cl)


# --- helpers ------------------------------------------------------------------

## One channel's transport: PASS 0 writes the outflow into `send`; barrier; PASS 1 gathers and applies in place.
func _carry(rd: RenderingDevice, cl: int, uset: RID, ctx: Dictionary, cc: int, groups: int, n_plates: int,
		matrix_channel: bool) -> void:
	if not uset.is_valid():
		return
	for pass_id in 2:
		rd.compute_list_bind_compute_pipeline(cl, _pipe)
		rd.compute_list_bind_uniform_set(cl, uset, 0)
		var pc: PackedByteArray = _push(ctx, cc, pass_id, n_plates, matrix_channel)
		rd.compute_list_set_push_constant(cl, pc, pc.size())
		rd.compute_list_dispatch(cl, groups, 1, 1)
		rd.compute_list_add_barrier(cl)


## std430: 4x uint (cell_count, pass_id, n_plates, depth) then 4x float (dt, lat_size, max_mass,
## pore_scale) — 32 bytes. pore_scale 1 = `fld` is a rock-matrix saturation, 0 = it is mineral.
func _push(ctx: Dictionary, cc: int, pass_id: int, n_plates: int,
		matrix_channel: bool) -> PackedByteArray:
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(32)
	pc.encode_u32(0, cc)
	pc.encode_u32(4, pass_id)
	pc.encode_u32(8, maxi(n_plates, 0))
	pc.encode_u32(12, _ctx_depth(ctx))
	pc.encode_float(16, _ctx_num(ctx, "dt"))
	pc.encode_float(20, _ctx_num(ctx, "lat_size"))
	pc.encode_float(24, _ctx_num(ctx, "max_mass"))
	pc.encode_float(28, 1.0 if matrix_channel else 0.0)
	return pc
