extends "res://addons/local_agents/sim/material/sphere_passes/SpherePass.gd"

## Everything that moves between cells, through one kernel: transport.glsl once per LATransportRecords row.

const KERNEL_PATH: String = "res://addons/local_agents/sim/material/kernels3d/transport.glsl"

const BandsScript: GDScript = preload("res://addons/local_agents/sim/material/AbsorptionBands.gd")
const CellListScript: GDScript = preload("res://addons/local_agents/sim/material/sphere_passes/CellListPass.gd")

## Which half of the gather a dispatch is, plus the prologue that runs before any row; tags, not quantities.
enum { PASS_OUTFLOW, PASS_GATHER, PASS_GRAIN }

## The grain prologue carries mineral grains, so the Stokes law reads silicate's density off `substance`.
const GRAIN_ROW: Dictionary = {"channel": "silicate", "substance": "silicate",
	"mode": LATransportRecords.POTENTIAL}

## Below this a cell is empty and does not donate. Declared in docs/MODEL_PARAMETERS.md.
const MIN_AMOUNT: float = 0.0001

var _pipe: RID = RID()
## Per row: its uniform set. An invalid entry is a row whose buffers the driver has not got.
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
## Per cell: the broadband longwave emissivity and the solar-beam share, stamped by the RADIATE row's pass 0
## and marched by its pass 1. Scratch of one dispatch pair, like _send — never read outside the step.
var _lw_emis: RID = RID()
var _sw_abs: RID = RID()
var _band_count: int = 0
## The grain prologue's uniform set.
var _grain_set: RID = RID()
## Per row: the dispatch-indirect args RID of the cell list it runs over, invalid for a full-grid row.
var _list_args: Array = []


## What the TF_STAMP gather publishes about the electric field: driver-owned so ReducePass and
## CellListPass can read them, and not a derived channel, which would be read back with no CPU consumer.
func _buffers(cc: int) -> Dictionary:
	return {"col_e": cc, "strike": cc, "radiogenic": cc}


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
	_lw_emis = _scratch(cc)
	_sw_abs = _scratch(cc)

	for row: Dictionary in _rows:
		_sets.append(_row_set(bufs, row))
		_list_args.append(_single(bufs, String(_list_keys(row).get("args", ""))))
	_grain_set = _row_set(bufs, GRAIN_ROW)


func dispatch(rd: RenderingDevice, cl: int, ctx: Dictionary, cc: int, groups: int) -> void:
	if not _dispatchable():
		return
	var cell_m: float = _ctx_cell_size(ctx)
	var dt_s: float = LAMaterialFieldSphereStep3D.real_seconds_per_step()
	var sun: Vector3 = ctx.get("sun_dir", Vector3.ZERO)
	# PROLOGUE. The three suspension shares are the `frac` of three silicate rows, so they must be complete
	# before those rows donate, and it reads `cement` before the dilute rows rescale it.
	if _grain_set.is_valid():
		rd.compute_list_bind_compute_pipeline(cl, _pipe)
		rd.compute_list_bind_uniform_set(cl, _grain_set, 0)
		var gpc: PackedByteArray = _pc(GRAIN_ROW, cc, PASS_GRAIN, cell_m, dt_s, sun)
		rd.compute_list_set_push_constant(cl, gpc, gpc.size())
		rd.compute_list_dispatch(cl, groups, 1, 1)
		rd.compute_list_add_barrier(cl)
	for r in _rows.size():
		var uset: RID = _sets[r]
		if not uset.is_valid():
			continue
		# EVERY ROW RUNS TWICE. Pass 0 writes what leaves each face; pass 1 gathers. A receiver reading a
		# donor inside one dispatch reads a value another thread is still writing.
		var args: RID = _list_args[r]
		for pass_id in [PASS_OUTFLOW, PASS_GATHER]:
			rd.compute_list_bind_compute_pipeline(cl, _pipe)
			rd.compute_list_bind_uniform_set(cl, uset, 0)
			var pc: PackedByteArray = _pc(_rows[r], cc, pass_id, cell_m, dt_s, sun)
			rd.compute_list_set_push_constant(cl, pc, pc.size())
			# A listed row walks the cells CellListPass compacted, so its cost is O(active), not O(grid).
			if args.is_valid():
				rd.compute_list_dispatch_indirect(cl, args, 0)
			else:
				rd.compute_list_dispatch(cl, groups, 1, 1)
			rd.compute_list_add_barrier(cl)


# --- bindings ---------------------------------------------------------------------------------------------

## The cell-list buffer keys a row runs over; empty for a row that sweeps the whole grid.
func _list_keys(row: Dictionary) -> Dictionary:
	var label: String = String(row.get("list", ""))
	return {} if label == "" else CellListScript.list_buffers(label)

## The uniform set for one row, or RID() when a buffer it names does not exist.
func _row_set(bufs: Dictionary, row: Dictionary) -> RID:
	var channel: String = String(row["channel"])
	var drive: String = String(row.get("drive", ""))
	var resist: String = String(row.get("resist", ""))
	var aux: String = String(row.get("aux", ""))
	var frac: String = String(row.get("frac", ""))
	var moves_enthalpy: bool = channel == "h_j_m3"
	# Mass does not move without its heat, so the enthalpy field is required of every row that carries mass.
	var list: Dictionary = _list_keys(row)
	var needed: Array = [channel, drive, resist, aux, frac, "" if moves_enthalpy else "h_j_m3",
		String(list.get("idx", "")), String(list.get("args", "")), String(list.get("flag", ""))]
	for key in needed:
		if String(key) != "" and not bufs.has(key):
			push_error("TransportPass: no \"%s\" buffer, so the %s row does not move." % [key, channel])
			return RID()
	# The material state every law and the band model read. A missing one is a dead row, not a default.
	for key in ["h_h2o", "h_silicate", "h_sensible", "cap_sensible",
			"temp", "pressure", "porosity", "grain", "co2", "h2o", "h2o_solid", "h2o_liquid",
			"h2o_vapour", "silicate", "biomass", "silicate_melt", "cement",
			"silicate_susp_water", "silicate_susp_air", "silicate_bed",
			"rad_absorbed", "rad_emitted", "col_e", "strike",
			"carbonate", "silica", "radiogenic"]:
		if not bufs.has(key):
			push_error("TransportPass: no \"%s\" buffer, so the %s row has no law." % [key, channel])
			return RID()
	var amount: RID = _single(bufs, channel)
	var entries: Array = [
		[0, amount],
		[1, _no_h if moves_enthalpy else _single(bufs, "h_j_m3")],
		[2, _single(bufs, "nbr")],
		[3, _single(bufs, "solid")],
		[4, _single(bufs, "gravity")],
		[5, _single(bufs, "vel_x")], [6, _single(bufs, "vel_y")], [7, _single(bufs, "vel_z")],
		[8, _send], [9, _send_h],
		[10, _zero if resist == "" else _single(bufs, resist)],
		[11, amount if drive == "" else _single(bufs, drive)],
		[12, _one if aux == "" else _single(bufs, aux)],
		[13, _single(bufs, "charge")], [14, _send_q],
		[15, _single(bufs, "temp")],
		[16, _single(bufs, "pressure")],
		[17, _single(bufs, "porosity")],
		[18, _single(bufs, "grain")],
		[19, _single(bufs, "co2")],
		[20, _single(bufs, "h2o")],
		[21, _rad_table],
		[22, _single(bufs, "h2o_solid")],
		[23, _single(bufs, "h2o_liquid")],
		[24, _single(bufs, "silicate")],
		[25, _single(bufs, "biomass")],
		[26, _single(bufs, "silicate_melt")],
		[28, _single(bufs, "h2o_vapour")],
		[29, _one if frac == "" else _single(bufs, frac)],
		[30, _single(bufs, "cement")],
		[31, _single(bufs, "silicate_susp_water")],
		[32, _single(bufs, "silicate_susp_air")],
		[33, _single(bufs, "silicate_bed")],
		# A full-grid row never reads these; the kernel touches them only under TF_LISTED.
		[34, _zero if list.is_empty() else bufs[String(list["idx"])]],
		[35, _zero if list.is_empty() else bufs[String(list["args"])]],
		[36, _zero if list.is_empty() else bufs[String(list["flag"])]],
		# Every row binds these; only a MODE_RADIATE gather writes them.
		[37, _single(bufs, "rad_absorbed")],
		[38, _single(bufs, "rad_emitted")],
		[39, _single(bufs, "col_e")],
		[40, _single(bufs, "strike")],
		# The other two rock channels and where the radiogenic tail books what it deposited.
		[41, _single(bufs, "carbonate")],
		[42, _single(bufs, "silica")],
		[43, _single(bufs, "radiogenic")],
		[44, _lw_emis],
		[45, _sw_abs],
		# Heat travels with the matter that holds it, so a row reads the enthalpy of ITS OWN entry.
		[46, _single(bufs, _carried_key(String(row["substance"])))],
		[47, _single(bufs, "cap_sensible")],
	]
	return _uset(_pipe, entries)


## The buffer holding the enthalpy of the mixture entry a substance's heat sits in.
func _carried_key(substance: String) -> String:
	match LAMatterChannels.entry_of(substance):
		LAMatterChannels.Entry.H2O:
			return "h_h2o"
		LAMatterChannels.Entry.SILICATE:
			return "h_silicate"
	return "h_sensible"


# --- push constant ----------------------------------------------------------------------------------------

## transport.glsl's Params block, in its declared order — 104 bytes.
func _pc(row: Dictionary, cc: int, pass_id: int, cell_m: float, dt_s: float,
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
	if bool(row.get("efield", false)):
		flags |= LATransportRecords.Flag.EFIELD
	if String(row.get("drive", "")) != "":
		flags |= LATransportRecords.Flag.DRIVEN
	if String(row.get("frac", "")) != "":
		flags |= LATransportRecords.Flag.FRACTION
	if bool(row.get("dilute", false)):
		flags |= LATransportRecords.Flag.DILUTE
	if String(row.get("list", "")) != "":
		flags |= LATransportRecords.Flag.LISTED
	if bool(row.get("radiogenic", false)):
		flags |= LATransportRecords.Flag.RADIOGENIC
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(104)
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
	pc.encode_float(48, fluid.x)
	pc.encode_float(52, fluid.y)
	# Seed diameter for cells whose own grain field is unset; the cell's value wins wherever it has one.
	pc.encode_float(56, LAPhysical.GRAIN_D_UPLAND_M)
	pc.encode_float(60, sun.x)
	pc.encode_float(64, sun.y)
	pc.encode_float(68, sun.z)
	var water: Vector2 = LATransportRecords.fluid_properties(LATransportRecords.Fluid.WATER)
	var air: Vector2 = LATransportRecords.fluid_properties(LATransportRecords.Fluid.AIR)
	pc.encode_float(72, water.x)
	pc.encode_float(76, water.y)
	pc.encode_float(80, air.x)
	pc.encode_float(84, air.y)
	# The nuclide store is finite, so the rate FALLS: this is what each rock has left at the run's epoch.
	var epoch: float = LARadiogenicDecay.epoch_years()
	pc.encode_float(88, LARadiogenicDecay.heat_production_w_m3_at("silicate", epoch))
	pc.encode_float(92, LARadiogenicDecay.heat_production_w_m3_at("carbonate", epoch))
	pc.encode_float(96, LARadiogenicDecay.heat_production_w_m3_at("silica", epoch))
	# J/m^3/K one unit of fill contributes to the sensible entry; 0 for a substance on a phase ladder,
	# whose entry is the channel itself.
	pc.encode_float(100, float(entry.get("density", 0.0)) * LAMatterChannels.specific_heat(substance))
	return pc


func _filled(n: int, v: float) -> PackedByteArray:
	var a: PackedFloat32Array = PackedFloat32Array()
	a.resize(n)
	a.fill(v)
	return a.to_byte_array()
