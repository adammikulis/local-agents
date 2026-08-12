extends "res://addons/local_agents/sim/material/sphere_passes/SpherePass.gd"

## Everything that moves between cells, through one kernel: transport.glsl once per LATransportRecords row.

const KERNEL_PATH: String = "res://addons/local_agents/sim/material/kernels3d/transport.glsl"

const BandsScript: GDScript = preload("res://addons/local_agents/sim/material/AbsorptionBands.gd")

## Which half of the gather a dispatch is; a tag, not a quantity.
enum { PASS_OUTFLOW, PASS_GATHER }

## Below this a cell is empty and does not donate. Declared in docs/MODEL_PARAMETERS.md.
const MIN_AMOUNT: float = 0.0001

var _pipe: RID = RID()
## Per row: [set(parity 0), set(parity 1)]. An empty entry is a row whose buffers the driver has not got.
var _sets: Array = []
var _rows: Array = []
## Per-face scratch, cell*6: what left each face this step, and the enthalpy and charge that rode with it.
var _send: RID = RID()
var _send_h: RID = RID()
var _send_q: RID = RID()
## resist 0 and aux 1 for a row that names neither.
var _zero: RID = RID()
var _one: RID = RID()
## Enthalpy of transported enthalpy: there is none, so a row moving `h_j_m3` carries this instead of
## aliasing its own amount buffer.
var _no_h: RID = RID()
## Band edges, absorption coefficients and the Planck CDF the RADIATE row reads.
var _rad_table: RID = RID()
var _band_count: int = 0


func _setup(bufs: Dictionary, cc: int) -> void:
	_pipe = _kernel(KERNEL_PATH)
	_rows = LATransportRecords.rows()

	_send = _scratch(cc * 6)
	_send_h = _scratch(cc * 6)
	_send_q = _scratch(cc * 6)
	_zero = _scratch(cc)
	_no_h = _scratch(cc)
	_one = _storage_buffer(_filled(cc, 1.0))
	_band_count = BandsScript.BAND_COUNT
	_rad_table = _storage_buffer(BandsScript.packed().to_byte_array())

	for row: Dictionary in _rows:
		_sets.append(_row_sets(bufs, row))


func dispatch(rd: RenderingDevice, cl: int, parity: int, ctx: Dictionary, cc: int, groups: int) -> void:
	if not _dispatchable():
		return
	var cell_m: float = _ctx_cell_size(ctx)
	var dt_s: float = LAMaterialFieldSphereStep3D.real_seconds_per_step()
	# Dry adiabat, K/m: g over the specific heat of dry air at constant pressure.
	var lapse: float = _ctx_num(ctx, "g_m_s2") / LAPhysical.AIR_SPECIFIC_HEAT_J_KGK
	var sun: Vector3 = ctx.get("sun_dir", Vector3.ZERO)
	for r in _rows.size():
		var uset: RID = _sets[r][parity] if not (_sets[r] as Array).is_empty() else RID()
		if not uset.is_valid():
			continue
		# EVERY ROW RUNS TWICE. Pass 0 writes what leaves each face; pass 1 gathers. A receiver reading a
		# donor inside one dispatch reads a value another thread is still writing.
		for pass_id in [PASS_OUTFLOW, PASS_GATHER]:
			rd.compute_list_bind_compute_pipeline(cl, _pipe)
			rd.compute_list_bind_uniform_set(cl, uset, 0)
			var pc: PackedByteArray = _pc(_rows[r], cc, pass_id, cell_m, dt_s, lapse, sun)
			rd.compute_list_set_push_constant(cl, pc, pc.size())
			rd.compute_list_dispatch(cl, groups, 1, 1)
			rd.compute_list_add_barrier(cl)


# --- bindings ---------------------------------------------------------------------------------------------

## [set(parity 0), set(parity 1)] for one row, or [] when a buffer it names does not exist.
func _row_sets(bufs: Dictionary, row: Dictionary) -> Array:
	var channel: String = String(row["channel"])
	var drive: String = String(row.get("drive", ""))
	var resist: String = String(row.get("resist", ""))
	var aux: String = String(row.get("aux", ""))
	var stamp: String = String(row.get("stamp", ""))
	var frac: String = String(row.get("frac", ""))
	var moves_enthalpy: bool = channel == "h_j_m3"
	# Mass does not move without its heat, so the enthalpy field is required of every row that carries mass.
	var needed: Array = [channel, drive, resist, aux, stamp, frac, "" if moves_enthalpy else "h_j_m3"]
	for key in needed:
		if String(key) != "" and not bufs.has(key):
			push_error("TransportPass: no \"%s\" buffer, so the %s row does not move." % [key, channel])
			return []
	# The material state every law and the band model read. A missing one is a dead row, not a default.
	for key in ["temp", "pressure", "porosity", "grain", "co2", "h2o", "h2o_solid", "h2o_liquid",
			"h2o_vapour", "rock_fill", "biomass", "lava"]:
		if not bufs.has(key):
			push_error("TransportPass: no \"%s\" buffer, so the %s row has no law." % [key, channel])
			return []
	var out: Array = [RID(), RID()]
	for p in 2:
		var amount: RID = _half(bufs, channel, p, false)
		var entries: Array = [
			[0, amount],
			[1, _no_h if moves_enthalpy else _half(bufs, "h_j_m3", p, false)],
			[2, _single(bufs, "nbr")],
			[3, _single(bufs, "solid")],
			[4, _single(bufs, "gravity")],
			[5, _single(bufs, "vel_x")], [6, _single(bufs, "vel_y")], [7, _single(bufs, "vel_z")],
			[8, _send], [9, _send_h],
			[10, _zero if resist == "" else _half(bufs, resist, p, false)],
			[11, amount if drive == "" else _half(bufs, drive, p, false)],
			[12, _one if aux == "" else _half(bufs, aux, p, false)],
			[13, _single(bufs, "charge")], [14, _send_q],
			[15, _single(bufs, "temp")],
			[16, _single(bufs, "pressure")],
			[17, _single(bufs, "porosity")],
			[18, _single(bufs, "grain")],
			[19, _half(bufs, "co2", p, false)],
			[20, _half(bufs, "h2o", p, false)],
			[21, _rad_table],
			[22, _single(bufs, "h2o_solid")],
			[23, _single(bufs, "h2o_liquid")],
			[24, _single(bufs, "rock_fill")],
			[25, _single(bufs, "biomass")],
			[26, _half(bufs, "lava", p, false)],
			[27, _send_q if stamp == "" else _half(bufs, stamp, p, false)],
			[28, _single(bufs, "h2o_vapour")],
			[29, _one if frac == "" else _single(bufs, frac)],
		]
		out[p] = _uset(_pipe, entries)
	return out


# --- push constant ----------------------------------------------------------------------------------------

## { uint cell_count, pass_id, mode, law, band_count, flags; float cell_m, dt_s, repose_tan, min_amount,
## density, max_fill, lapse_k_per_m, fluid_rho, fluid_visc, grain_d, sun_x, sun_y, sun_z; } — 76 bytes.
func _pc(row: Dictionary, cc: int, pass_id: int, cell_m: float, dt_s: float, lapse: float,
		sun: Vector3) -> PackedByteArray:
	var substance: String = String(row["substance"])
	var entry: Dictionary = LASubstances.table().get(substance, {})
	var fluid: Vector2 = LATransportRecords.fluid_properties(
		int(row.get("fluid", LATransportRecords.Fluid.VACUUM)))
	var flags: int = 0
	if bool(row.get("signed", false)):
		flags |= LATransportRecords.Flag.SIGNED
	if bool(row.get("settle", false)):
		flags |= LATransportRecords.Flag.SETTLE
	if String(row.get("stamp", "")) != "":
		flags |= LATransportRecords.Flag.STAMP
	if String(row.get("drive", "")) != "":
		flags |= LATransportRecords.Flag.DRIVEN
	if String(row.get("frac", "")) != "":
		flags |= LATransportRecords.Flag.FRACTION
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(76)
	pc.encode_u32(0, cc)
	pc.encode_u32(4, pass_id)
	pc.encode_u32(8, int(row["mode"]))
	pc.encode_u32(12, int(row.get("law", LATransportRecords.Law.NONE)))
	pc.encode_u32(16, _band_count)
	pc.encode_u32(20, flags)
	pc.encode_float(24, cell_m)
	pc.encode_float(28, dt_s)
	pc.encode_float(32, float(row.get("repose_tan", 0.0)))
	pc.encode_float(36, MIN_AMOUNT)
	pc.encode_float(40, float(entry.get("density", 0.0)))
	# Enthalpy, momentum and a shock front are not matter occupying volume, so no cell is ever full of them.
	pc.encode_float(44, LATransportRecords.max_fill(substance) if substance != "" else INF)
	pc.encode_float(48, lapse)
	pc.encode_float(52, fluid.x)
	pc.encode_float(56, fluid.y)
	# Airborne dust and suspended load are silt-grade; the aquifer's own grain field overrides it in-cell.
	pc.encode_float(60, LAPhysical.GRAIN_D_UPLAND_M)
	pc.encode_float(64, sun.x)
	pc.encode_float(68, sun.y)
	pc.encode_float(72, sun.z)
	return pc


func _filled(n: int, v: float) -> PackedByteArray:
	var a: PackedFloat32Array = PackedFloat32Array()
	a.resize(n)
	a.fill(v)
	return a.to_byte_array()
