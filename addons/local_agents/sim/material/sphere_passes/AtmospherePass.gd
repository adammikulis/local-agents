extends "res://addons/local_agents/sim/material/sphere_passes/SpherePass.gd"


const Tracer = preload("res://addons/local_agents/sim/material/sphere_passes/TracerTransport.gd")

const PRECIP_PATH: String = "res://addons/local_agents/sim/material/kernels3d/atmos_precip_sphere3d.glsl"
const RAIN_PATH: String = "res://addons/local_agents/sim/material/kernels3d/atmos_rain_sphere3d.glsl"

# --- PRECIPITATION IS A MICROPHYSICAL PROCESS, NOT A CEILING -----------------------------------------------
const AUTOCONVERSION_RATE_PER_S: float = 1.0e-3    # Kessler (1969) k_auto
const CLOUD_WATER_CRIT_KG_KG: float = 0.5e-3       # Kessler (1969) q_crit, cloud-water mixing ratio

const MOISTURE_DIFFUSE: float = 0.035


## The autoconversion threshold in the field's own unit (fraction of a cell full of liquid water).
static func rain_threshold() -> float:
	return CLOUD_WATER_CRIT_KG_KG * LAPhysical.AIR_DENSITY_KG_M3 / LAPhysical.WATER_DENSITY_KG_M3


## Fraction of the supercritical cloud water shed as rain in ONE field step. Kessler's rate is per SECOND and
## a field step stands for LAMaterialFieldSphereStep3D.real_seconds_per_step() of them, so the conversion is
## the substrate's own clock rather than a per-step number anybody chose.
static func rain_rate_per_step() -> float:
	return clampf(AUTOCONVERSION_RATE_PER_S * LAMaterialFieldSphereStep3D.real_seconds_per_step(), 0.0, 1.0)


var _transport_pipe: RID = RID()
var _precip_pipe: RID = RID()
var _rain_pipe: RID = RID()

var _rain_buf: RID = RID()
# Private moisture scratch — the transport's output and the precip's input. With evaporation dissolved into
# the reaction engine there are two moisture-writing stages left, and a two-link ping-pong cannot both start
# in live and end in back.
var _moist_buf: RID = RID()
# The transport's deposit binding. Atmospheric water has no settled phase here (precipitation is the next
# stage), so this is never written — but it may not alias the in or out buffers, which are `restrict`.
var _deposit_dump: RID = RID()

# One uniform set per kernel per parity p (index 0/1). Picked by `parity` at dispatch.
var _transport_set: Array = [RID(), RID()]
var _precip_set: Array = [RID(), RID()]
var _rain_set: Array = [RID(), RID()]


func _setup(bufs: Dictionary, cc: int) -> void:
	_transport_pipe = _kernel(Tracer.KERNEL_PATH)
	_precip_pipe = _kernel(PRECIP_PATH)
	_rain_pipe = _kernel(RAIN_PATH)

	_rain_buf = _scratch(cc)
	_moist_buf = _scratch(cc)
	_deposit_dump = _scratch(cc)

	var moisture: Array = _pair(bufs, "moisture")
	var temp: Array = _pair(bufs, "temp")
	var water: Array = _pair(bufs, "water")
	var solid: RID = _single(bufs, "solid")
	var nbr: RID = _single(bufs, "nbr")
	var cvol: RID = _single(bufs, "cell_vol")

	for p in 2:
		var back: int = 1 - p

		# moisture[live] -> the private scratch.
		_transport_set[p] = _uset(_transport_pipe,
			Tracer.bindings(bufs, moisture[p], _moist_buf, _deposit_dump))

		# PRECIP — atmos_precip_sphere3d.glsl: 0=moisture in(post-transport scratch), 1=temp(back), 2=solid,
		# 3=moisture out(back), 4=rain scratch.
		_precip_set[p] = _uset(_precip_pipe, [
			[0, _moist_buf], [1, temp[back]], [2, solid], [3, moisture[back]], [4, _rain_buf]])

		# RAIN — atmos_rain_sphere3d.glsl: 0=rain scratch, 1=solid, 2=water(back, in place += rain), 15=nbr,
		# 40=cell_vol (the column gather crosses cells of different volume).
		_rain_set[p] = _uset(_rain_pipe, [
			[0, _rain_buf], [1, solid], [2, water[back]], [15, nbr], [40, cvol]])


func dispatch(rd: RenderingDevice, cl: int, parity: int, ctx: Dictionary, cc: int, groups: int) -> void:
	if not _dispatchable():
		return
	# The LATERAL spacing the transport's Courant factor is taken against; the kernel rescales it per radial
	# face from the shell table.
	var lat_size: float = _ctx_num(ctx, "lat_size")

	# STAGE 1 — TRANSPORT: moisture[live] --(weak diffuse / vel_y updraft advection / horizontal wind)-->
	# the private scratch (one conservative pass). vel_y advection is what CLUMPS the field into cloud masses.
	rd.compute_list_bind_compute_pipeline(cl, _transport_pipe)
	rd.compute_list_bind_uniform_set(cl, _transport_set[parity], 0)
	var pc_tr: PackedByteArray = Tracer.push_constant(cc, _ctx_depth(ctx), Tracer.courant(lat_size),
			Tracer.gas_settle_v(LAPhysical.MOLAR_MASS_WATER_KG_MOL), MOISTURE_DIFFUSE, false, lat_size)
	rd.compute_list_set_push_constant(cl, pc_tr, pc_tr.size())
	rd.compute_list_dispatch(cl, groups, 1, 1)
	rd.compute_list_add_barrier(cl)          # post-transport scratch visible to precip

	# STAGE 2 — PRECIPITATION: derive condensed = max(0, moisture − sat(T)); autoconvert the part over the
	# critical cloud-water content to rain in the scratch; scratch -> moisture[back].
	rd.compute_list_bind_compute_pipeline(cl, _precip_pipe)
	rd.compute_list_bind_uniform_set(cl, _precip_set[parity], 0)
	rd.compute_list_set_push_constant(cl, _pc_precip(cc), 16)
	rd.compute_list_dispatch(cl, groups, 1, 1)
	rd.compute_list_add_barrier(cl)          # rain scratch visible to the rain gather

	# STAGE 3 — RAIN GATHER: route each cell's rain down the radial column; water[back] += rain, in place.
	rd.compute_list_bind_compute_pipeline(cl, _rain_pipe)
	rd.compute_list_bind_uniform_set(cl, _rain_set[parity], 0)
	var pc_rain: PackedByteArray = _pc_cells(cc)
	rd.compute_list_set_push_constant(cl, pc_rain, pc_rain.size())
	rd.compute_list_dispatch(cl, groups, 1, 1)
	rd.compute_list_add_barrier(cl)          # water[back] settle visible to downstream passes


# --- helpers ------------------------------------------------------------------

# PRECIP push constant: {uint cell_count, float rain_threshold, float rain_rate, uint pad} (16 bytes). Both
# floats are DERIVED above (Kessler autoconversion against the substrate's own clock and the real air/water
# densities) rather than declared in the kernel, so there is exactly one copy of each and nothing to drift.
func _pc_precip(cc: int) -> PackedByteArray:
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(16)
	pc.encode_u32(0, cc)
	pc.encode_float(4, rain_threshold())
	pc.encode_float(8, rain_rate_per_step())
	pc.encode_u32(12, 0)
	return pc
