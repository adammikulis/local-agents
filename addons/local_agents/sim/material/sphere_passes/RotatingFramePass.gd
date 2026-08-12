extends "res://addons/local_agents/sim/material/sphere_passes/SpherePass.gd"

## Coriolis and centrifugal on the momentum channels. The field's axes are body-local and the body spins,
## so this is a rotating frame. LAPhysical.CORIOLIS_TWO_OMEGA_RAD_S was read only by a LEDGER, which
## booked the force while the momentum equation never felt it.

const KERNEL_PATH: String = "res://addons/local_agents/sim/material/kernels3d/rotating_frame.glsl"

var _pipe: RID = RID()
var _set: Array = [RID(), RID()]


func _setup(bufs: Dictionary, _cc: int) -> void:
	_pipe = _kernel(KERNEL_PATH)
	var missing: PackedStringArray = PackedStringArray()
	for name: String in ["mom_x", "mom_y", "mom_z", "vel_x", "vel_y", "vel_z",
			"rho_cond", "n_gas_m3", "pos"]:
		if not _half(bufs, name, 0, false).is_valid():
			missing.append(name)
	if not missing.is_empty():
		push_error("RotatingFramePass: no buffer for %s, so the frame terms never reach momentum."
			% String(", ").join(missing))
		return
	for p in 2:
		_set[p] = _uset(_pipe, [
			[0, _half(bufs, "mom_x", p, false)],
			[1, _half(bufs, "mom_y", p, false)],
			[2, _half(bufs, "mom_z", p, false)],
			[3, _single(bufs, "vel_x")],
			[4, _single(bufs, "vel_y")],
			[5, _single(bufs, "vel_z")],
			[6, _single(bufs, "rho_cond")],
			[7, _single(bufs, "n_gas_m3")],
			[8, _single(bufs, "pos")]])


func dispatch(rd: RenderingDevice, cl: int, parity: int, ctx: Dictionary, cc: int, groups: int) -> void:
	if not _dispatchable() or not _set[parity].is_valid():
		return
	var w: Vector3 = ctx.get("spin", Vector3.ZERO) * LAPhysical.PLANET_ANGULAR_VELOCITY_RAD_S
	var centre: Vector3 = ctx.get("centre", Vector3.ZERO)
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(36)
	pc.encode_u32(0, cc)
	pc.encode_float(4, LAMaterialFieldSphereStep3D.real_seconds_per_step())
	pc.encode_float(8, w.x)
	pc.encode_float(12, w.y)
	pc.encode_float(16, w.z)
	pc.encode_float(20, LAPhysical.MOLAR_MASS_DRY_AIR_KG_MOL)
	pc.encode_float(24, centre.x)
	pc.encode_float(28, centre.y)
	pc.encode_float(32, centre.z)
	rd.compute_list_bind_compute_pipeline(cl, _pipe)
	rd.compute_list_bind_uniform_set(cl, _set[parity], 0)
	rd.compute_list_set_push_constant(cl, pc, pc.size())
	rd.compute_list_dispatch(cl, groups, 1, 1)
