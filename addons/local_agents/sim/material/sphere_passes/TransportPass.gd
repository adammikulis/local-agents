extends "res://addons/local_agents/sim/material/sphere_passes/SpherePass.gd"

## Everything that moves between cells, through one kernel: transport.glsl once per LATransportRecords row.

const KERNEL_PATH: String = "res://addons/local_agents/sim/material/kernels3d/transport.glsl"

const BandsScript: GDScript = preload("res://addons/local_agents/sim/material/AbsorptionBands.gd")
const BoundaryRowsScript: GDScript = preload("res://addons/local_agents/sim/material/reduce/BoundaryRows.gd")

## Which half of the gather a dispatch is, the grain prologue, the three compaction dispatches that
## build each LATransportRecords.lists() list, and the RADIATE row's reflected-shortwave march.
enum { PASS_OUTFLOW, PASS_GATHER, PASS_GRAIN, PASS_LIST_RESET, PASS_LIST_APPEND, PASS_LIST_ARGS,
	PASS_SW }

## List-args buffer layout, shared with the kernel: 0-2 are the uvec3 an indirect dispatch reads, 3 is the
## atomic list length. SLOTS is the buffer's element count.
enum Arg { GROUPS_X = 0, GROUPS_Y = 1, GROUPS_Z = 2, LIST_COUNT = 3, SLOTS = 8 }

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
## The reflected-shortwave march's scratch pair: the share of upwelling flux a cell keeps, and each
## cell's reflected source. Stamped by the RADIATE row's passes 0 and 1, marched by its PASS_SW.
var _sw_keep: RID = RID()
var _sw_src: RID = RID()
var _band_count: int = 0
## The grain prologue's uniform set.
var _grain_set: RID = RID()
## Per row: the dispatch-indirect args RID of the cell list it runs over, invalid for a full-grid row.
var _list_args: Array = []
## Per LATransportRecords.lists() entry: the synthetic row its compaction dispatches carry, its uniform
## set, and its args/idx buffer RIDs.
var _list_rows: Array = []
var _list_sets: Array = []
var _list_args_rid: Array = []
var _list_idx_rid: Array = []


## What the TF_EFIELD row's outflow pass publishes about the electric field (driver-owned so ReducePass can
## read them, not a derived channel, which would be read back with no CPU consumer), plus each list's
## compacted-index, membership-flag and indirect-args buffers.
func _buffers(cc: int) -> Dictionary:
	var out: Dictionary = {"col_e": cc, "strike": cc, "radiogenic": cc,
		"sw_space": cc,
		"bnd_void": cc, "bnd_h_void": cc, "rim_ghost": cc, "rim_w": cc}
	for ch in BoundaryRowsScript.BOOKED:
		out["bnd_" + String(ch)] = cc
		out["bnd_h_" + String(ch)] = cc
	for ch in BoundaryRowsScript.BOOKED_SIGNED:
		out["bnd_" + String(ch)] = cc
	for lrow: Dictionary in LATransportRecords.lists():
		var keys: Dictionary = LATransportRecords.list_buffers(String(lrow["label"]))
		out[String(keys["idx"])] = cc
		out[String(keys["flag"])] = cc
		out[String(keys["args"])] = {"n": int(Arg.SLOTS), "indirect": true}
	return out


func _setup(bufs: Dictionary, cc: int) -> void:
	_pipe = _kernel(KERNEL_PATH)
	_rows = LATransportRecords.rows()

	# Ghost tail cells run pass 0, so every buffer the kernel indexes by cell carries the tail.
	var tc: int = cc + ghost_count
	_send = _scratch(tc * 6)
	_send_h = _scratch(tc * 6)
	_send_q = _scratch(tc * 6)
	_zero = _scratch(tc)
	_no_h = _scratch(tc)
	_one = _storage_buffer(_filled(tc, 1.0))
	_band_count = BandsScript.BAND_COUNT
	_rad_table = _storage_buffer(BandsScript.packed().to_byte_array())
	_lw_emis = _scratch(tc)
	_sw_abs = _scratch(tc)
	_sw_keep = _scratch(tc)
	_sw_src = _scratch(tc)

	for row: Dictionary in _rows:
		_sets.append(_row_set(bufs, row))
		_list_args.append(_single(bufs, String(_list_keys(row).get("args", ""))))
	_grain_set = _row_set(bufs, GRAIN_ROW)
	# The append's predicate reads `drive`, which binds the list's prim channel through `channel`.
	for lrow: Dictionary in LATransportRecords.lists():
		var label: String = String(lrow["label"])
		var keys: Dictionary = LATransportRecords.list_buffers(label)
		_list_rows.append({"label": label, "channel": String(lrow["prim"]), "substance": "",
			"mode": LATransportRecords.POTENTIAL, "halo": bool(lrow.get("halo", false)),
			"emit_idx": bool(lrow.get("emit_idx", false)), "list": label})
		_list_sets.append(_row_set(bufs, _list_rows.back()))
		_list_args_rid.append(_single(bufs, String(keys["args"])))
		_list_idx_rid.append(_single(bufs, String(keys["idx"])))


func dispatch(rd: RenderingDevice, cl: int, ctx: Dictionary, cc: int, groups: int) -> void:
	if not _dispatchable():
		return
	var cell_m: float = _ctx_cell_size(ctx)
	var dt_s: float = LAMaterialFieldSphereStep3D.real_seconds_per_step()
	var sun: Vector3 = ctx.get("sun_dir", Vector3.ZERO)
	# THE LISTS, rebuilt before any listed row dispatches over one: RESET the counter, APPEND the interior
	# cells the predicate keeps, publish the indirect ARGS.
	for r in _list_rows.size():
		var lset: RID = _list_sets[r]
		if not lset.is_valid():
			continue
		rd.compute_list_bind_compute_pipeline(cl, _pipe)
		rd.compute_list_bind_uniform_set(cl, lset, 0)
		for spec: Array in [[PASS_LIST_RESET, 1], [PASS_LIST_APPEND, groups], [PASS_LIST_ARGS, 1]]:
			var lpc: PackedByteArray = _pc(_list_rows[r], cc, int(spec[0]), cell_m, dt_s, sun)
			rd.compute_list_set_push_constant(cl, lpc, lpc.size())
			rd.compute_list_dispatch(cl, int(spec[1]), 1, 1)
			rd.compute_list_add_barrier(cl)
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
		# donor inside one dispatch reads a value another thread is still writing. The RADIATE row runs a
		# third time: the gather stamps each cell's reflected source, and PASS_SW marches the upwelling.
		var args: RID = _list_args[r]
		var passes: Array = [PASS_OUTFLOW, PASS_GATHER]
		if int(_rows[r]["mode"]) == LATransportRecords.RADIATE:
			passes.append(PASS_SW)
		for pass_id in passes:
			rd.compute_list_bind_compute_pipeline(cl, _pipe)
			rd.compute_list_bind_uniform_set(cl, uset, 0)
			var pc: PackedByteArray = _pc(_rows[r], cc, pass_id, cell_m, dt_s, sun)
			rd.compute_list_set_push_constant(cl, pc, pc.size())
			# A listed row walks the compacted cells, so its cost is O(active), not O(grid).
			if args.is_valid():
				rd.compute_list_dispatch_indirect(cl, args, 0)
			else:
				# Pass 0 covers the ghost tail; the driver's group count covers interior only.
				var g: int = groups
				if pass_id == PASS_OUTFLOW and ghost_count > 0:
					g = int(ceil(float(cc + ghost_count) / 64.0))
				rd.compute_list_dispatch(cl, g, 1, 1)
			rd.compute_list_add_barrier(cl)


# --- bindings ---------------------------------------------------------------------------------------------

## Cells each list holds after the last step, and for an `emit_idx` list the indices themselves, reading
## only the occupied prefix.
func _drain(rd: RenderingDevice) -> Dictionary:
	var out: Dictionary = {}
	for r in _list_rows.size():
		var raw: PackedByteArray = rd.buffer_get_data(_list_args_rid[r])
		if raw.size() < int(Arg.SLOTS) * 4:
			continue
		var label: String = String(_list_rows[r]["label"])
		var n: int = raw.to_int32_array()[int(Arg.LIST_COUNT)]
		out[label + "_list_cells"] = float(n)
		if n > 0 and bool(_list_rows[r].get("emit_idx", false)):
			out[label + "_list_idx"] = rd.buffer_get_data(_list_idx_rid[r], 0, n * 4).to_int32_array()
	return out


## The cell-list buffer keys a row runs over; empty for a row that sweeps the whole grid.
func _list_keys(row: Dictionary) -> Dictionary:
	var label: String = String(row.get("list", ""))
	return {} if label == "" else LATransportRecords.list_buffers(label)

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
	if String(row.get("list", "")) != "" and list.is_empty():
		push_error("TransportPass: no \"%s\" list, so the %s row does not move."
			% [String(row["list"]), channel])
		return RID()
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
			"carbonate", "silica", "radiogenic", "sw_space",
			"ghost", "bnd_void", "bnd_h_void"]:
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
		[27, _single(bufs, "ghost")],
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
		# A booked channel's boundary crossings; an unbooked row writes a void pair nothing reads.
		# A signed channel books its amount leg only; the kernel never writes its heat leg.
		[48, _single(bufs, ("bnd_" + channel) if (BoundaryRowsScript.BOOKED.has(channel)
			or BoundaryRowsScript.BOOKED_SIGNED.has(channel)) else "bnd_void")],
		[49, _single(bufs, ("bnd_h_" + channel) if BoundaryRowsScript.BOOKED.has(channel) else "bnd_h_void")],
		# The REPLAY relaxation rim, filled by LAFieldBoundary3D.attach; all-zero weights without one.
		[50, _single(bufs, "rim_ghost")],
		[51, _single(bufs, "rim_w")],
		# The reflected-shortwave field: pass-owned scratch pair, then the escape book the reduce
		# row reads.
		[52, _sw_keep],
		[53, _sw_src],
		[54, _single(bufs, "sw_space")],
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
	if bool(row.get("halo", false)):
		flags |= LATransportRecords.Flag.LIST_HALO
	if bool(row.get("relax", false)):
		flags |= LATransportRecords.Flag.RELAX
	if bool(row.get("radiogenic", false)):
		flags |= LATransportRecords.Flag.RADIOGENIC
	# The row whose amount IS enthalpy books joules on both boundary legs.
	if String(row["channel"]) == "h_j_m3":
		flags |= LATransportRecords.Flag.ENTHALPY
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(108)
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
	pc.encode_u32(104, cc + ghost_count)
	return pc


func _filled(n: int, v: float) -> PackedByteArray:
	var a: PackedFloat32Array = PackedFloat32Array()
	a.resize(n)
	a.fill(v)
	return a.to_byte_array()
