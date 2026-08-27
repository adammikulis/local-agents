extends "res://addons/local_agents/sim/material/sphere_passes/SpherePass.gd"

## Everything that moves between cells, through one kernel: transport.glsl once per LATransportRecords row.

const KERNEL_PATH: String = "res://addons/local_agents/sim/material/kernels3d/transport.glsl"

const BoundaryRowsScript: GDScript = preload("res://addons/local_agents/sim/material/reduce/BoundaryRows.gd")
const LevelsScript: GDScript = preload("res://addons/local_agents/sim/material/sphere_passes/TemporalLevels.gd")

## Dispatch tags: the gather halves, the grain prologue, the list compaction, the RADIATE row's
## reflected-shortwave march, and the acoustic pair.
enum { PASS_OUTFLOW, PASS_GATHER, PASS_GRAIN, PASS_LIST_RESET, PASS_LIST_APPEND, PASS_LIST_ARGS,
	PASS_SW, PASS_ACOUSTIC, PASS_ACOUSTIC_APPLY,
	PASS_LEVEL_SEED, PASS_LEVEL_RELAX, PASS_LEVEL_RESET, PASS_LEVEL_HIST, PASS_LEVEL_SCAN,
	PASS_LEVEL_SORT, PASS_LEVEL_PEAK }

## List-args layout: 0-2 the indirect uvec3, 3 the atomic list length, SLOTS the element count.
enum Arg { GROUPS_X = 0, GROUPS_Y = 1, GROUPS_Z = 2, LIST_COUNT = 3, SLOTS = 8 }

## The grain prologue carries mineral grains, so the Stokes law reads silicate's density off `substance`.
const GRAIN_ROW: Dictionary = {"channel": "silicate", "substance": "silicate",
	"mode": LATransportRecords.POTENTIAL}

## kg/m^3 below which a cell is empty: it donates nothing and holds no bulk velocity. The one emptiness
## floor, read by transport.glsl and state_derive.glsl. Declared in docs/MODEL_PARAMETERS.md.
const EMPTY_RHO_KG_M3: float = 0.0001 * LAPhysical.AIR_DENSITY_KG_M3

var _pipe: RID = RID()
## The pressure half-step the acoustic group takes after its rows, on the group's last row's set.
const ACOUSTIC_PAIR: Array = [PASS_ACOUSTIC, PASS_ACOUSTIC_APPLY]

## Dispatches one submit may hold. The device waits on a fence to read a buffer back, and a submit
## longer than that wait fails; splitting the recording changes nothing dispatched, only when.
const FLUSH_EVERY: int = 4096

var _recorded: int = 0

## Rows that advance together on one time axis; a solitary row is its own group.
var _row_groups: Array = []
## Per group: the finest temporal level its own state asked for, read back before the step records;
## -1 = a state no timestep integrates. `_peak_top` is the finest any group asked, for the drain.
var _peaks: PackedInt32Array = PackedInt32Array()
var _peak_top: int = 0
var _args_rid: RID = RID()
var _peak_rid: RID = RID()
## Per row: its uniform set. An invalid entry is a row whose buffers the driver has not got.
var _sets: Array = []
var _rows: Array = []
## Per-face scratch, cell*6: what left each face this step, and the enthalpy and charge that rode with it.
var _send: RID = RID()
var _send_h: RID = RID()
var _send_q: RID = RID()
## Momentum riding each face's mass flux, one scratch per component.
var _send_m: Array = []
## resist 0 and aux 1 for a row that names neither.
var _zero: RID = RID()
var _one: RID = RID()
## Enthalpy of transported enthalpy: none, so a row moving `h_j_m3` carries this zero buffer.
var _no_h: RID = RID()
## Band edges, absorption coefficients and the Planck CDF the RADIATE row reads.
var _rad_table: RID = RID()
## Broadband longwave emissivity and solar-beam share, the RADIATE row's own within-step scratch.
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
## Per LATransportRecords.lists() entry: its synthetic row, uniform set, and args/idx RIDs.
var _list_rows: Array = []
var _list_sets: Array = []
var _list_args_rid: Array = []
var _list_idx_rid: Array = []


## The TF_EFIELD row's electric-field outputs (driver-owned so ReducePass can read them), the boundary
## books, and each list's compacted-index, membership-flag and indirect-args buffers.
func _buffers(cc: int) -> Dictionary:
	var out: Dictionary = {"col_e": cc, "strike": cc, "radiogenic": cc,
		"sw_space": cc, "rad_residual": cc,
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
	out.merge(LevelsScript.buffers(cc + ghost_count, _grouping(LATransportRecords.rows()).size()))
	return out


## Consecutive rows that advance on ONE time axis: the acoustic pair and the momentum rows it carries.
func _grouping(rows: Array) -> Array:
	var out: Array = []
	for r in rows.size():
		if r > 0 and _group_row(rows[r]) and _group_row(rows[r - 1]):
			out[out.size() - 1].append(r)
			continue
		out.append(PackedInt32Array([r]))
	return out


func _setup(bufs: Dictionary, cc: int) -> void:
	_pipe = _kernel(KERNEL_PATH)
	_rows = LATransportRecords.rows()
	_row_groups = _grouping(_rows)
	_peaks.resize(_row_groups.size())
	_args_rid = _single(bufs, LevelsScript.KEYS.args)
	_peak_rid = _single(bufs, LevelsScript.KEYS.peak)

	# Ghost tail cells run pass 0, so every buffer the kernel indexes by cell carries the tail.
	var tc: int = cc + ghost_count
	_send = _scratch(tc * 6)
	_send_h = _scratch(tc * 6)
	_send_q = _scratch(tc * 6)
	_send_m = [_scratch(tc * 6), _scratch(tc * 6), _scratch(tc * 6)]
	_zero = _scratch(tc)
	_no_h = _scratch(tc)
	_one = _storage_buffer(_filled(tc, 1.0))
	var rad_table: PackedFloat32Array = LAAbsorptionBands.packed()
	_band_count = int(rad_table[0])
	_rad_table = _storage_buffer(rad_table.to_byte_array())
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


## XUV irradiance at this body, W/m^2, taken once per dispatch off the ctx the star publishes into.
var _xuv_w_m2: float = 0.0


func dispatch(rd: RenderingDevice, cl: int, ctx: Dictionary, cc: int, groups: int) -> void:
	if not _dispatchable():
		return
	var cell_m: float = _ctx_cell_size(ctx)
	var dt_s: float = _ctx_num(ctx, "dt_s")
	var sun: Vector3 = ctx.get("sun_dir", Vector3.ZERO)
	# No sun in the ctx is no star, which is no XUV — never an assumed one.
	_xuv_w_m2 = float(ctx.get("xuv_w_m2", 0.0))
	_pc_cache.clear()
	# THE LISTS, rebuilt before any listed row dispatches over one.
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
	# PROLOGUE: the suspension shares three silicate rows read as `frac`, before anything donates.
	if _grain_set.is_valid():
		rd.compute_list_bind_compute_pipeline(cl, _pipe)
		rd.compute_list_bind_uniform_set(cl, _grain_set, 0)
		var gpc: PackedByteArray = _pc(GRAIN_ROW, cc, PASS_GRAIN, cell_m, dt_s, sun)
		rd.compute_list_set_push_constant(cl, gpc, gpc.size())
		rd.compute_list_dispatch(cl, groups, 1, 1)
		rd.compute_list_add_barrier(cl)
	# EACH GROUP ON ITS OWN TIME AXIS. The acoustic group substeps as one unit: matter advects, the
	# gathers refresh velocity, and the acoustic half-step advances the pressure.
	for g in _row_groups.size():
		var group: PackedInt32Array = _row_groups[g]
		var levels: int = _peaks[g] if g < _peaks.size() else 0
		if levels < 0:
			continue
		_build_levels(rd, cl, group, cc, cell_m, dt_s, sun, levels, groups)
		var n: int = 1 << levels
		# The acoustic pair rides the group's last row, so that row carrying velocity IS the test.
		var acoustic: bool = _vel_row(_rows[group[group.size() - 1]])
		for k in n:
			var lk: int = LevelsScript.coarsest_at(k, levels)
			for gi in group:
				_run_row(rd, cl, gi, cc, cell_m, dt_s, sun, groups, lk, k, n)
			if acoustic:
				_run_row(rd, cl, group[group.size() - 1], cc, cell_m, dt_s, sun, groups, lk, k, n,
					ACOUSTIC_PAIR)
			_recorded += group.size()
			if _recorded > FLUSH_EVERY:
				cl = _flush(rd)


## THE LEVEL FIELD, once per group: seed each row's own need, relax 2:1 against the neighbours, then
## counting-sort every cell by level so a substep dispatches over the suffix at that level or finer.
func _build_levels(rd: RenderingDevice, cl: int, group: PackedInt32Array, cc: int, cell_m: float,
		dt_s: float, sun: Vector3, levels: int, groups: int) -> void:
	var tail: int = int(ceil(float(cc + ghost_count) / 64.0))
	_one_dispatch(rd, cl, group[0], cc, PASS_LEVEL_RESET, cell_m, dt_s, sun, LevelsScript.BINS, tail)
	if levels <= 0:
		return
	for gi in group:
		_one_dispatch(rd, cl, gi, cc, PASS_LEVEL_SEED, cell_m, dt_s, sun, 0, groups)
	# The fixed point of "no neighbour is more than one level finer" is `levels` sweeps away at most.
	for _i in levels:
		_one_dispatch(rd, cl, group[0], cc, PASS_LEVEL_RELAX, cell_m, dt_s, sun, 0, groups)
	for spec: Array in [[PASS_LEVEL_HIST, groups], [PASS_LEVEL_SCAN, 1], [PASS_LEVEL_SORT, groups]]:
		_one_dispatch(rd, cl, group[0], cc, int(spec[0]), cell_m, dt_s, sun, LevelsScript.BINS,
			int(spec[1]))


## Hand the device what is recorded so far and open the next list; the id is the same either way.
func _flush(rd: RenderingDevice) -> int:
	rd.compute_list_end()
	rd.submit()
	rd.sync()
	_recorded = 0
	return rd.compute_list_begin()


func _one_dispatch(rd: RenderingDevice, cl: int, r: int, cc: int, pass_id: int, cell_m: float,
		dt_s: float, sun: Vector3, level: int, groups: int) -> void:
	if not _sets[r].is_valid():
		return
	rd.compute_list_bind_compute_pipeline(cl, _pipe)
	rd.compute_list_bind_uniform_set(cl, _sets[r], 0)
	var pc: PackedByteArray = _pc(_rows[r], cc, pass_id, cell_m, dt_s, sun, level)
	rd.compute_list_set_push_constant(cl, pc, pc.size())
	rd.compute_list_dispatch(cl, groups, 1, 1)
	rd.compute_list_add_barrier(cl)


## THE PEAK LEVEL PER GROUP, before the step records: a submit of its own, so the loop bounds come from
## the state this step starts in rather than from a reading one step stale.
func pre_step(rd: RenderingDevice, ctx: Dictionary, cc: int, groups: int) -> void:
	if not _dispatchable() or not _peak_rid.is_valid() or _row_groups.is_empty():
		return
	var cell_m: float = _ctx_cell_size(ctx)
	var dt_s: float = _ctx_num(ctx, "dt_s")
	rd.buffer_clear(_peak_rid, 0, _row_groups.size() * 4)
	var cl: int = rd.compute_list_begin()
	for g in _row_groups.size():
		for gi in _row_groups[g]:
			_one_dispatch(rd, cl, gi, cc, PASS_LEVEL_PEAK, cell_m, dt_s, Vector3.ZERO, g, groups)
	rd.compute_list_end()
	rd.submit()
	rd.sync()
	_peaks = rd.buffer_get_data(_peak_rid, 0, _row_groups.size() * 4).to_int32_array()
	# A CELL ASKING FOR A STEP SHORTER THAN LIGHT TAKES TO CROSS IT IS NOT ASKING FOR RESOLUTION.
	# Its state is broken, no subdivision integrates it, and its group does not move this step.
	var lim: int = LevelsScript.light_level(dt_s, cell_m)
	_peak_top = 0
	for g in _peaks.size():
		_peak_top = maxi(_peak_top, _peaks[g])
		if _peaks[g] < lim:
			continue
		_peaks[g] = -1
		push_error("TransportPass: the %s row's own cells carry a signal speed at or past light, so "
			% String(_rows[_row_groups[g][0]]["channel"]) + "no timestep integrates them.")


## One row's outflow+gather pair; the RADIATE row runs a third pass, PASS_SW, marching the upwelling
## its gather stamped. The rim's nudge is a per-STEP fraction, so only the last substep carries RELAX.
func _run_row(rd: RenderingDevice, cl: int, r: int, cc: int, cell_m: float, dt_s: float,
		sun: Vector3, groups: int, level: int, k: int, n: int, only: Array = []) -> void:
	var uset: RID = _sets[r]
	if not uset.is_valid():
		return
	var args: RID = _list_args[r]
	var passes: Array = only
	if passes.is_empty():
		passes = [PASS_OUTFLOW, PASS_GATHER]
		if int(_rows[r]["mode"]) == LATransportRecords.RADIATE:
			passes.append(PASS_SW)
	for pass_id in passes:
		rd.compute_list_bind_compute_pipeline(cl, _pipe)
		rd.compute_list_bind_uniform_set(cl, uset, 0)
		var pc: PackedByteArray = _pc_at(r, cc, pass_id, cell_m, dt_s, sun, level, k, n)
		rd.compute_list_set_push_constant(cl, pc, pc.size())
		# Past level 0 the row walks the sorted suffix: its cost is O(cells this substep), not O(grid).
		if level > 0:
			rd.compute_list_dispatch_indirect(cl, _args_rid, level * LevelsScript.SLOTS * 4)
		elif args.is_valid():
			# A listed row walks the compacted cells, so its cost is O(active), not O(grid).
			rd.compute_list_dispatch_indirect(cl, args, 0)
		else:
			# Pass 0 covers the ghost tail; the driver's group count covers interior only.
			var g: int = groups
			if pass_id == PASS_OUTFLOW and ghost_count > 0:
				g = int(ceil(float(cc + ghost_count) / 64.0))
			rd.compute_list_dispatch(cl, g, 1, 1)
		rd.compute_list_add_barrier(cl)


## A signed per-axis momentum row, whose gather refreshes its velocity component.
func _vel_row(row: Dictionary) -> bool:
	return row.has("axis") and bool(row.get("signed", false))


## A row of the acoustic substep group: a momentum row, or compressible matter flagged into it.
func _group_row(row: Dictionary) -> bool:
	return _vel_row(row) or bool(row.get("acoustic", false))


## Cells each list holds after the last step; an `emit_idx` list also returns its occupied prefix.
func _drain(rd: RenderingDevice) -> Dictionary:
	var out: Dictionary = {"transport_levels": float(_peak_top)}
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
		String(list.get("idx", "")), String(list.get("args", "")), String(list.get("flag", "")),
		LevelsScript.KEYS.level, LevelsScript.KEYS.idx, LevelsScript.KEYS.args, LevelsScript.KEYS.peak]
	for key in needed:
		if String(key) != "" and not bufs.has(key):
			push_error("TransportPass: no \"%s\" buffer, so the %s row does not move." % [key, channel])
			return RID()
	# The material state every law and the band model read. A missing one is a dead row, not a default.
	for key in ["h_h2o", "h_silicate", "h_sensible", "cap_sensible",
			"temp", "pressure", "porosity", "grain", "co2", "ch4", "co", "so2", "h2s",
			"o2", "n2", "h2", "grav_phi",
			"h2o", "h2o_solid", "h2o_liquid",
			"h2o_vapour", "silicate", "biomass", "silicate_melt", "cement",
			"silicate_susp_water", "silicate_susp_air", "silicate_bed",
			"rad_absorbed", "rad_emitted", "col_e", "strike",
			"rad_w_m3", "radiogenic", "sw_space", "rad_residual",
			"ghost", "bnd_void", "bnd_h_void", "rho_bulk",
			"mom_x", "mom_y", "mom_z", "celerity", "speed", "bodyf_x", "bodyf_y", "bodyf_z"]:
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
		# The composition-derived radiogenic power, and where its tail books what it deposited.
		[41, _single(bufs, "rad_w_m3")],
		# The minor greenhouse gases the band table resolves.
		[42, _single(bufs, "ch4")],
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
		# The reflected-shortwave field: pass-owned scratch pair, then the escape book and the
		# Stefan-Boltzmann residual the reduce rows read.
		[52, _sw_keep],
		[53, _sw_src],
		[54, _single(bufs, "sw_space")],
		[55, _single(bufs, "rad_residual")],
		# O3 partial density, kg/m^3: zeros until a photochemical o3 channel exists to swap in.
		[56, _zero],
		[57, _single(bufs, "rho_bulk")],
		[58, _single(bufs, "mom_x")],
		[59, _single(bufs, "mom_y")],
		[60, _single(bufs, "mom_z")],
		[61, _send_m[0]], [62, _send_m[1]], [63, _send_m[2]],
		[64, _single(bufs, "celerity")],
		[65, _single(bufs, "speed")],
		[66, _single(bufs, "bodyf_x")],
		[67, _single(bufs, "bodyf_y")],
		[68, _single(bufs, "bodyf_z")],
		# The momentum riding a mass row's exterior crossing; a signed row books through binding 48
		# and binds the void here.
		[69, _single(bufs, "bnd_void" if bool(row.get("signed", false)) else "bnd_mom_x")],
		[70, _single(bufs, "bnd_void" if bool(row.get("signed", false)) else "bnd_mom_y")],
		[71, _single(bufs, "bnd_void" if bool(row.get("signed", false)) else "bnd_mom_z")],
		[72, _single(bufs, "co")],
		[73, _single(bufs, "so2")],
		[74, _single(bufs, "h2s")],
		[75, _single(bufs, "o2")],
		[76, _single(bufs, "n2")],
		[77, _single(bufs, "h2")],
		# The solved potential, J/kg: -phi is the escape energy LAW_ESCAPE lifts against.
		[78, _single(bufs, "grav_phi")],
		# The charge riding a mass row's crossing; a signed channel books its own through binding 48.
		[79, _single(bufs, "bnd_void" if BoundaryRowsScript.BOOKED_SIGNED.has(channel) else "bnd_charge")],
		# The temporal level field, the cells sorted by it, the per-level args, and the group peaks.
		[80, _single(bufs, LevelsScript.KEYS.level)],
		[81, _single(bufs, LevelsScript.KEYS.idx)],
		[82, _single(bufs, LevelsScript.KEYS.args)],
		[83, _single(bufs, LevelsScript.KEYS.peak)],
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

## Row keys the kernel unpacks as flags: a switch it reads as a bool, and a key it reads as named-or-not.
const SWITCHES: Array = [["signed", LATransportRecords.Flag.SIGNED],
	["settle", LATransportRecords.Flag.SETTLE], ["efield", LATransportRecords.Flag.EFIELD],
	["dilute", LATransportRecords.Flag.DILUTE], ["halo", LATransportRecords.Flag.LIST_HALO],
	["relax", LATransportRecords.Flag.RELAX], ["radiogenic", LATransportRecords.Flag.RADIOGENIC]]
const NAMED: Array = [["drive", LATransportRecords.Flag.DRIVEN],
	["frac", LATransportRecords.Flag.FRACTION], ["list", LATransportRecords.Flag.LISTED]]


## A substep only moves the level and its index along, so the rest of the block is built once per row,
## pass and level class per step: at thousands of substeps the encoding IS the dispatch cost.
var _pc_cache: Dictionary = {}


func _pc_at(r: int, cc: int, pass_id: int, cell_m: float, dt_s: float, sun: Vector3,
		level: int, k: int, n: int) -> PackedByteArray:
	var key: int = (r * 32 + pass_id) * 2 + (1 if level > 0 else 0)
	var pc: PackedByteArray = _pc_cache.get(key, PackedByteArray())
	if pc.is_empty():
		pc = _pc(_rows[r], cc, pass_id, cell_m, dt_s, sun, level, k, n)
		_pc_cache[key] = pc
	pc.encode_u32(104, level)
	pc.encode_u32(108, k)
	pc.encode_u32(112, n)
	return pc


## transport.glsl's Params block, in its declared order.
func _pc(row: Dictionary, cc: int, pass_id: int, cell_m: float, dt_s: float,
		sun: Vector3, level: int = 0, substep_k: int = 0, substep_n: int = 1) -> PackedByteArray:
	var substance: String = String(row["substance"])
	var entry: Dictionary = LASubstances.table().get(substance, {})
	var fluid: Vector2 = LATransportRecords.fluid_properties(
		int(row.get("fluid", LATransportRecords.Fluid.VACUUM)))
	var flags: int = LATransportRecords.Flag.VEL if _vel_row(row) else 0
	if level > 0:
		flags |= LATransportRecords.Flag.LEVEL
	for pair: Array in SWITCHES:
		if bool(row.get(String(pair[0]), false)):
			flags |= int(pair[1])
	for pair2: Array in NAMED:
		if String(row.get(String(pair2[0]), "")) != "":
			flags |= int(pair2[1])
	# The row whose amount IS enthalpy books joules on both boundary legs.
	if String(row["channel"]) == "h_j_m3":
		flags |= LATransportRecords.Flag.ENTHALPY
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(116)
	pc.encode_u32(0, cc)
	pc.encode_u32(4, pass_id)
	pc.encode_u32(8, int(row["mode"]))
	pc.encode_u32(12, int(row.get("law", LATransportRecords.Law.NONE)))
	pc.encode_u32(16, _band_count)
	pc.encode_u32(20, flags)
	pc.encode_float(24, cell_m)
	pc.encode_float(28, dt_s)
	pc.encode_float(32, float(row.get("repose_tan", 0.0)))
	var max_fill: float = LATransportRecords.max_fill(substance) if substance != "" else INF
	pc.encode_float(36, EMPTY_RHO_KG_M3)
	pc.encode_float(40, float(entry.get("density", 0.0)))
	# Enthalpy, momentum and a shock front are not matter occupying volume, so no cell is ever full of them.
	pc.encode_float(44, max_fill)
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
	# J/m^3/K one mol/m^3 of the substance contributes to the sensible entry (molar mass times specific
	# heat); 0 for a substance on a phase ladder, whose entry is the channel itself.
	pc.encode_float(88, float(entry.get("molar_mass", 0.0)) * LAMatterChannels.specific_heat(substance))
	pc.encode_u32(92, cc + ghost_count)
	pc.encode_u32(96, int(row.get("axis", 0)))
	# XUV irradiance AT THIS BODY, already distance-corrected by the star that emitted it; the zenith
	# cosine is what still scales it in-kernel.
	pc.encode_float(100, _xuv_w_m2)
	pc.encode_u32(104, level)
	pc.encode_u32(108, substep_k)
	pc.encode_u32(112, substep_n)
	return pc


func _filled(n: int, v: float) -> PackedByteArray:
	var a: PackedFloat32Array = PackedFloat32Array()
	a.resize(n)
	a.fill(v)
	return a.to_byte_array()
