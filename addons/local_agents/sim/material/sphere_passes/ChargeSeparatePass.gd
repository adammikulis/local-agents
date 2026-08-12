extends "res://addons/local_agents/sim/material/sphere_passes/SpherePass.gd"

## Non-inductive charge separation, and nothing else. Breakdown is the OHMIC row of LATransportRecords:
## a medium whose conductivity rises past the runaway threshold, not a strike list.

const SEPARATE_PATH: String = "res://addons/local_agents/sim/material/kernels3d/charge_separate.glsl"

var _pipe: RID = RID()
var _sets: Array = [RID(), RID()]


func _setup(bufs: Dictionary, _cc: int) -> void:
	_pipe = _kernel(SEPARATE_PATH)
	for k in ["charge", "temp", "moisture", "nbr", "gravity", "vel_x", "vel_y", "vel_z"]:
		if not bufs.has(k):
			push_error("ChargeSeparatePass: no \"%s\" buffer, so no charge is ever separated." % k)
			return
	for p in 2:
		_sets[p] = _uset(_pipe, [
			[0, _single(bufs, "charge")],
			[1, _half(bufs, "temp", p, false)],
			[2, _half(bufs, "moisture", p, false)],
			[3, _single(bufs, "nbr")],
			[4, _single(bufs, "gravity")],
			[5, _single(bufs, "vel_x")],
			[6, _single(bufs, "vel_y")],
			[7, _single(bufs, "vel_z")]])


func dispatch(rd: RenderingDevice, cl: int, parity: int, _ctx: Dictionary, cc: int, groups: int) -> void:
	if not _dispatchable() or not _sets[parity].is_valid():
		return
	rd.compute_list_bind_compute_pipeline(cl, _pipe)
	rd.compute_list_bind_uniform_set(cl, _sets[parity], 0)
	var pc: PackedByteArray = _pc(cc, LAMaterialFieldSphereStep3D.real_seconds_per_step())
	rd.compute_list_set_push_constant(cl, pc, pc.size())
	rd.compute_list_dispatch(cl, groups, 1, 1)
	rd.compute_list_add_barrier(cl)


# Params { uint cell_count; float dt_s; float rate_c_m3_s; float zone_warm_c; float zone_cold_c;
#          float updraft_ref; float lwc_ref; uint pad0; } — 32 bytes.
func _pc(cc: int, dt_s: float) -> PackedByteArray:
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(32)
	pc.encode_u32(0, cc)
	pc.encode_float(4, dt_s)
	pc.encode_float(8, LAPhysical.NIC_CHARGE_RATE_C_M3_S)
	pc.encode_float(12, LAPhysical.CHARGE_ZONE_WARM_C)
	pc.encode_float(16, LAPhysical.CHARGE_ZONE_COLD_C)
	pc.encode_float(20, LAPhysical.CONVECTIVE_UPDRAFT_M_S)
	pc.encode_float(24, LAPhysical.CHARGING_LWC_KG_M3)
	pc.encode_u32(28, 0)
	return pc
