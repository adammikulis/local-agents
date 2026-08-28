extends "res://addons/local_agents/sim/material/sphere_passes/SpherePass.gd"

## Everything that moves between cells, through one kernel: transport.glsl once per LATransportRecords row.

const KERNEL_PATH: String = "res://addons/local_agents/sim/material/kernels3d/transport.glsl"

const BoundaryRowsScript: GDScript = preload("res://addons/local_agents/sim/material/reduce/BoundaryRows.gd")
const LevelsScript: GDScript = preload("res://addons/local_agents/sim/material/sphere_passes/TemporalLevels.gd")
const ActiveScript: GDScript = preload("res://addons/local_agents/sim/material/sphere_passes/ActiveCells.gd")

## Dispatch tags: the gather halves, the grain prologue, the detector compaction, the RADIATE row's
## reflected-shortwave march, the acoustic pair, the temporal levels and the active-cell list.
enum { PASS_OUTFLOW, PASS_GATHER, PASS_GRAIN, PASS_LIST_RESET, PASS_LIST_APPEND, PASS_LIST_ARGS,
	PASS_SW, PASS_ACOUSTIC, PASS_ACOUSTIC_APPLY,
	PASS_LEVEL_SEED, PASS_LEVEL_RELAX, PASS_LEVEL_RESET, PASS_LEVEL_SCAN,
	PASS_LEVEL_SORT, PASS_LEVEL_PEAK,
	PASS_ACT_AGE, PASS_ACT_WAKE, PASS_ACT_MARK, PASS_ACT_WAKE_RESET, PASS_ACT_SEED }

## transport.glsl's ACT_NO_GROUP: this row's crossings wake no second group.
const NO_GROUP: int = 0xffffffff

## List-args layout: 0-2 the indirect uvec3, 3 the atomic list length, 4 the sorted offset, 5 the
## scatter cursor, 6 the suffix count at this level or finer, SLOTS the element count.
enum Arg { GROUPS_X = 0, GROUPS_Y = 1, GROUPS_Z = 2, LIST_COUNT = 3, OFFSET = 4, CURSOR = 5,
	SUFFIX = 6, SLOTS = 8 }

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
var _idx_rid: RID = RID()
var _quiet_rid: RID = RID()
var _wake_rid: RID = RID()
var _wake_args_rid: RID = RID()
## Interior cells plus the ghost tail, and the row -> its group slot.
var _total: int = 0
var _row_group: PackedInt32Array = PackedInt32Array()
## Something outside this pass wrote the field, so the next step seeds every list with the whole box.
var _wake_pending: bool = true
## Per row: its uniform set. An invalid entry is a row whose buffers the driver has not got.
var _sets: Array = []
var _rows: Array = []
## Per-face scratch, cell*6: what left each face this step, and the enthalpy and charge that rode with it.
## Pass-owned scratch, binding to buffer: what left each face and the enthalpy, charge and momentum
## that rode with it, then the RADIATE row's own within-step emissivity, beam share and reflected pair.
var _scr: Dictionary = {}
## resist 0 and aux 1 for a row that names neither.
var _zero: RID = RID()
var _one: RID = RID()
## Enthalpy of transported enthalpy: none, so a row moving `h_j_m3` carries this zero buffer.
var _no_h: RID = RID()
## Band edges, absorption coefficients and the Planck CDF the RADIATE row reads.
var _rad_table: RID = RID()
var _band_count: int = 0
## The grain prologue's uniform set.
var _grain_set: RID = RID()
## Per LATransportRecords.lists() entry: its synthetic row, uniform set, and args/idx RIDs.
var _list_rows: Array = []
var _list_sets: Array = []
var _list_args_rid: Array = []
var _list_idx_rid: Array = []


## The TF_EFIELD row's electric-field outputs (driver-owned so ReducePass can read them), the boundary
## books, and each list's compacted-index, membership-flag and indirect-args buffers.
func _buffers(cc: int) -> Dictionary:
	# The acoustic pass writes `celerity`: the fastest layer on any of the cell's own faces.
	var out: Dictionary = {"col_e": cc, "strike": cc, "radiogenic": cc, "celerity": cc,
		"sw_space": cc, "rad_residual": cc,
		"bnd_void": cc, "bnd_h_void": cc, "rim_ghost": cc, "rim_w": cc}
	for ch in LAProcessSet.booked():
		out[BoundaryRowsScript.BOOKED_PREFIX + String(ch)] = cc
		if BoundaryRowsScript.BOOKED.has(ch):
			out[BoundaryRowsScript.HEAT_PREFIX + String(ch)] = cc
	for lrow: Dictionary in LATransportRecords.lists():
		var keys: Dictionary = LATransportRecords.list_buffers(String(lrow["label"]))
		out[String(keys["idx"])] = cc
		out[String(keys["args"])] = {"n": int(Arg.SLOTS), "indirect": true}
	out.merge(LevelsScript.buffers(cc + ghost_count, _group_count()))
	out.merge(ActiveScript.buffers(cc + ghost_count, _group_count()))
	return out


## One slot per row group, plus the grain prologue's own LAST: it derives where a cell's loose mineral
## sits, so it is awake wherever silicate moved rather than wherever anything did.
func _group_count() -> int:
	return _grouping(LAProcessSet.transport_rows()).size() + 1


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
	_rows = LAProcessSet.transport_rows()
	_row_groups = _grouping(_rows)
	_peaks.resize(_row_groups.size())
	_args_rid = _single(bufs, LevelsScript.KEYS.args)
	_peak_rid = _single(bufs, LevelsScript.KEYS.peak)
	_idx_rid = _single(bufs, LevelsScript.KEYS.idx)
	_quiet_rid = _single(bufs, ActiveScript.KEYS.quiet)
	_wake_rid = _single(bufs, ActiveScript.KEYS.wake)
	_wake_args_rid = _single(bufs, ActiveScript.KEYS.wake_args)
	_total = cc + ghost_count
	_row_group.resize(_rows.size())
	for g in _row_groups.size():
		for gi in _row_groups[g]:
			_row_group[gi] = g

	# Ghost tail cells run pass 0, so every buffer the kernel indexes by cell carries the tail.
	var tc: int = cc + ghost_count
	for i in SCRATCH:
		_scr[i] = _scratch(tc * 6 if i < FACE_SCRATCH else tc)
	_zero = _scratch(tc)
	_no_h = _scratch(tc)
	_one = _storage_buffer(_filled(tc, 1.0))
	var rad_table: PackedFloat32Array = LAAbsorptionBands.packed()
	_band_count = int(rad_table[0])
	_rad_table = _storage_buffer(rad_table.to_byte_array())

	for row: Dictionary in _rows:
		_sets.append(_row_set(bufs, row))
	_grain_set = _row_set(bufs, GRAIN_ROW)
	# The append's predicate reads `drive`, which binds the list's prim channel through `channel`.
	for lrow: Dictionary in LATransportRecords.lists():
		var label: String = String(lrow["label"])
		var keys: Dictionary = LATransportRecords.list_buffers(label)
		_list_rows.append({"label": label, "channel": String(lrow["prim"]), "substance": "",
			"mode": LATransportRecords.POTENTIAL,
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
	_seed_lists(rd, cl, cc, cell_m, dt_s)
	# THE DETECTOR LISTS: where the strikes and the non-finite values are. A detector looks everywhere
	# because a value it has never seen can sit anywhere; no row dispatches over one.
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
		var gslot: int = _group_count() - 1
		_act(rd, cl, _grain_set, GRAIN_ROW, cc, PASS_LEVEL_RESET, cell_m, dt_s, sun, gslot, 0, 0)
		_rebuild_active(rd, cl, _grain_set, GRAIN_ROW, cc, cell_m, dt_s, sun, gslot, 0, true)
		_act(rd, cl, _grain_set, GRAIN_ROW, cc, PASS_GRAIN, cell_m, dt_s, sun, gslot, 0, 0)
	# EACH GROUP ON ITS OWN TIME AXIS. The acoustic group substeps as one unit: matter advects, the
	# gathers refresh velocity, and the acoustic half-step advances the pressure.
	for g in _row_groups.size():
		var group: PackedInt32Array = _row_groups[g]
		var levels: int = _peaks[g] if g < _peaks.size() else 0
		if levels < 0:
			continue
		_build_levels(rd, cl, group, cc, cell_m, dt_s, sun, levels, g)
		var n: int = 1 << levels
		# The acoustic pair rides the group's last row, so that row carrying velocity IS the test.
		var acoustic: bool = _vel_row(_rows[group[group.size() - 1]])
		for k in n:
			var lk: int = LevelsScript.coarsest_at(k, levels)
			# THE BUBBLE, one substep at a time: age every listed cell, take in what another kernel
			# woke, and compact the awake cells and their receivers into the list the rows walk.
			_rebuild_active(rd, cl, _sets[group[0]], _rows[group[0]], cc, cell_m, dt_s, sun, g, lk,
				k == 0)
			for gi in group:
				_run_row(rd, cl, gi, cc, cell_m, dt_s, sun, lk, k, n)
			if acoustic:
				_run_row(rd, cl, group[group.size() - 1], cc, cell_m, dt_s, sun, lk, k, n,
					ACOUSTIC_PAIR)
			_recorded += group.size() + 4
			if _recorded > FLUSH_EVERY:
				cl = _flush(rd)
	# The wake queue is consumed; what the reactions write after this pass is next step's business.
	if _grain_set.is_valid():
		_fire(rd, cl, _grain_set, GRAIN_ROW, cc, PASS_ACT_WAKE_RESET, cell_m, dt_s, sun, 0, 0, RID(), 1)


## THE LISTS, before anything reads one: every cell of a world nobody has stepped yet, and every cell
## again after a CPU write no kernel saw. The only pass here that walks the box, and it runs on neither
## cadence — once at the seal, and once more whenever the field is written from outside.
func _seed_lists(rd: RenderingDevice, cl: int, cc: int, cell_m: float, dt_s: float) -> void:
	if not _wake_pending:
		return
	_wake_pending = false
	var wide: int = maxi(_total, (ActiveScript.QUEUE_BIN + 1) * _group_count())
	_fire(rd, cl, _grain_set, GRAIN_ROW, cc, PASS_ACT_SEED, cell_m, dt_s, Vector3.ZERO,
		_group_count(), 0, RID(), int(ceil(float(wide) / 64.0)))


## THE LEVEL FIELD, once per group over the cells it holds: clear it, seed each row's own need, then
## relax 2:1 against the neighbours. The counting sort that turns it into a dispatch list is the
## active-cell rebuild below, which runs every substep because the bubble grows every substep.
func _build_levels(rd: RenderingDevice, cl: int, group: PackedInt32Array, cc: int, cell_m: float,
		dt_s: float, sun: Vector3, levels: int, g: int) -> void:
	_act(rd, cl, _sets[group[0]], _rows[group[0]], cc, PASS_LEVEL_RESET, cell_m, dt_s, sun, g, 0, 0)
	if levels <= 0:
		return
	for gi in group:
		_act(rd, cl, _sets[gi], _rows[gi], cc, PASS_LEVEL_SEED, cell_m, dt_s, sun, g, 0, 0)
	# The fixed point of "no neighbour is more than one level finer" is `levels` sweeps away at most.
	for _i in levels:
		_act(rd, cl, _sets[group[0]], _rows[group[0]], cc, PASS_LEVEL_RELAX, cell_m, dt_s, sun, g, 0, 0)


## THE ACTIVE LIST for one group and substep, sorted by temporal level. Every dispatch here is over
## the list itself, so what it costs is what is moving, never what the box holds.
func _rebuild_active(rd: RenderingDevice, cl: int, uset: RID, row: Dictionary, cc: int,
		cell_m: float, dt_s: float, sun: Vector3, g: int, level: int, take_wake: bool) -> void:
	_act(rd, cl, uset, row, cc, PASS_ACT_AGE, cell_m, dt_s, sun, g, level, 0)
	if take_wake:
		_fire(rd, cl, uset, row, cc, PASS_ACT_WAKE, cell_m, dt_s, sun, g, level, _wake_args_rid, 0)
	_act(rd, cl, uset, row, cc, PASS_ACT_MARK, cell_m, dt_s, sun, g, level, 0)
	_fire(rd, cl, uset, row, cc, PASS_LEVEL_SCAN, cell_m, dt_s, sun, g, level, RID(), 1)
	_act(rd, cl, uset, row, cc, PASS_LEVEL_SORT, cell_m, dt_s, sun, g, level, ActiveScript.QUEUE_BIN)


## One dispatch over a group's own cell list, indirect off the bin's argument slot.
func _act(rd: RenderingDevice, cl: int, uset: RID, row: Dictionary, cc: int, pass_id: int,
		cell_m: float, dt_s: float, sun: Vector3, g: int, level: int, bin: int) -> void:
	_fire(rd, cl, uset, row, cc, pass_id, cell_m, dt_s, sun, g, level, _args_rid,
		ActiveScript.args_offset(g, bin))


## THE ONE DISPATCH SITE for everything but a row: indirect off `args` at `off`, or `off` workgroups
## straight when `args` names no buffer.
func _fire(rd: RenderingDevice, cl: int, uset: RID, row: Dictionary, cc: int, pass_id: int,
		cell_m: float, dt_s: float, sun: Vector3, g: int, level: int, args: RID, off: int) -> void:
	if not uset.is_valid():
		return
	rd.compute_list_bind_compute_pipeline(cl, _pipe)
	rd.compute_list_bind_uniform_set(cl, uset, 0)
	var pc: PackedByteArray = _pc(row, cc, pass_id, cell_m, dt_s, sun, level, 0, 1, g)
	rd.compute_list_set_push_constant(cl, pc, pc.size())
	if args.is_valid():
		rd.compute_list_dispatch_indirect(cl, args, off)
	else:
		rd.compute_list_dispatch(cl, off, 1, 1)
	rd.compute_list_add_barrier(cl)


## Every cell changed at once, from outside any kernel: the one seam a CPU writer has into the mask.
## The next step seeds every list with the whole box again, and the bubbles regrow from there.
func wake_all() -> void:
	_wake_pending = true


## Hand the device what is recorded so far and open the next list; the id is the same either way.
func _flush(rd: RenderingDevice) -> int:
	rd.compute_list_end()
	rd.submit()
	rd.sync()
	_recorded = 0
	return rd.compute_list_begin()


## THE PEAK LEVEL PER GROUP, before the step records: a submit of its own, so the loop bounds come from
## the state this step starts in rather than from a reading one step stale.
func pre_step(rd: RenderingDevice, ctx: Dictionary, cc: int, _groups: int) -> void:
	if not _dispatchable() or not _peak_rid.is_valid() or _row_groups.is_empty():
		return
	var cell_m: float = _ctx_cell_size(ctx)
	var dt_s: float = _ctx_num(ctx, "dt_s")
	rd.buffer_clear(_peak_rid, 0, _row_groups.size() * 4)
	var cl: int = rd.compute_list_begin()
	_seed_lists(rd, cl, cc, cell_m, dt_s)
	for g in _row_groups.size():
		for gi in _row_groups[g]:
			_act(rd, cl, _sets[gi], _rows[gi], cc, PASS_LEVEL_PEAK, cell_m, dt_s, Vector3.ZERO, g, g, 0)
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
		sun: Vector3, level: int, k: int, n: int, only: Array = []) -> void:
	var uset: RID = _sets[r]
	if not uset.is_valid() or not _args_rid.is_valid():
		return
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
		# THE ROW WALKS ITS GROUP'S ACTIVE CELLS at this level, ghost tail included: what it costs is
		# what is moving. There is no path here that dispatches over the box.
		rd.compute_list_dispatch_indirect(cl, _args_rid,
			ActiveScript.args_offset(_row_group[r], level))
		rd.compute_list_add_barrier(cl)


## A signed per-axis momentum row, whose gather refreshes its velocity component.
func _vel_row(row: Dictionary) -> bool:
	return row.has("axis") and bool(row.get("signed", false))


## A row of the acoustic substep group: a momentum row, or compressible matter flagged into it.
func _group_row(row: Dictionary) -> bool:
	return _vel_row(row) or bool(row.get("acoustic", false))


## Cells each list holds after the last step; an `emit_idx` list also returns its occupied prefix.
func _drain(rd: RenderingDevice) -> Dictionary:
	var out: Dictionary = {"transport_levels": float(_peak_top), "active_cells": _active_cells(rd)}
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


## Cells every group's list held at the end of the step: the width of one step's dispatches.
func _active_cells(rd: RenderingDevice) -> float:
	if not _args_rid.is_valid():
		return 0.0
	var args: PackedInt32Array = rd.buffer_get_data(_args_rid).to_int32_array()
	var stride: int = (ActiveScript.QUEUE_BIN + 1) * int(Arg.SLOTS)
	var n: int = 0
	for g in mini(_group_count(), args.size() / stride):
		n += args[g * stride + int(Arg.SUFFIX)]
	return float(n)


## Bindings that are just a driver buffer by name: its key to transport.glsl's binding number. ONE
## declaration of what this pass needs, so a buffer the driver never made is a named error, not a
## silent set. The level and activity names are LATemporalLevels.KEYS and LAActiveCells.KEYS.
const BINDINGS: Dictionary = {
	"nbr": 2, "solid": 3, "gravity": 4, "vel_x": 5, "vel_y": 6, "vel_z": 7, "charge": 13, "temp": 15,
	"pressure": 16, "porosity": 17, "grain": 18, "co2": 19, "h2o": 20, "h2o_solid": 22, "h2o_liquid": 23,
	"silicate": 24, "biomass": 25, "silicate_melt": 26, "ghost": 27, "h2o_vapour": 28, "cement": 30,
	"silicate_susp_water": 31, "silicate_susp_air": 32, "silicate_bed": 33, "rad_absorbed": 37,
	"rad_emitted": 38, "col_e": 39, "strike": 40, "rad_w_m3": 41, "ch4": 42, "radiogenic": 43,
	"cap_sensible": 47, "rim_ghost": 50, "rim_w": 51, "sw_space": 54, "rad_residual": 55, "rho_bulk": 57,
	"mom_x": 58, "mom_y": 59, "mom_z": 60, "celerity": 64, "speed": 65, "bodyf_x": 66, "bodyf_y": 67,
	"bodyf_z": 68, "co": 72, "so2": 73, "h2s": 74, "o2": 75, "n2": 76, "h2": 77, "grav_phi": 78,
	"tlevel": 80, "level_idx": 81, "level_args": 82, "level_peak": 83, "act_quiet": 84, "act_claim": 85,
	"act_queue": 86, "act_wake": 87, "act_wake_args": 88, "k_cond": 89
}

## Pass-owned scratch, in binding order: the first FACE_SCRATCH ride a face, the rest are per cell.
const SCRATCH: Dictionary = {0: 8, 1: 9, 2: 14, 3: 61, 4: 62, 5: 63, 6: 44, 7: 45, 8: 52, 9: 53}
const FACE_SCRATCH: int = 6




## The uniform set for one row, or RID() when a buffer it names does not exist.
func _row_set(bufs: Dictionary, row: Dictionary) -> RID:
	var channel: String = String(row["channel"])
	var drive: String = String(row.get("drive", ""))
	var resist: String = String(row.get("resist", ""))
	var aux: String = String(row.get("aux", ""))
	var frac: String = String(row.get("frac", ""))
	var moves_enthalpy: bool = channel == "h_j_m3"
	# Mass does not move without its heat, so the enthalpy field is required of every row that carries mass.
	# The detector-list buffers a synthetic row compacts into; empty for an ordinary row.
	var list: Dictionary = LATransportRecords.list_buffers(String(row.get("list", "")))
	var entries: Array = []
	for key in BINDINGS.keys() + [channel, drive, resist, aux, frac, "h_h2o", "h_silicate",
			"h_sensible", "bnd_void", "bnd_h_void", String(list.get("idx", "")),
			String(list.get("args", ""))]:
		var name: String = String(key)
		if name == "" or (name == "h_j_m3" and moves_enthalpy):
			continue
		if not bufs.has(name):
			push_error("TransportPass: no \"%s\" buffer, so the %s row does not move." % [name, channel])
			return RID()
		if BINDINGS.has(name):
			entries.append([BINDINGS[name], bufs[name]])
	for i in SCRATCH:
		entries.append([SCRATCH[i], _scr[i]])
	var amount: RID = _single(bufs, channel)
	entries += [
		[0, amount],
		[1, _no_h if moves_enthalpy else _single(bufs, "h_j_m3")],
		[10, _zero if resist == "" else _single(bufs, resist)],
		[11, amount if drive == "" else _single(bufs, drive)],
		[12, _one if aux == "" else _single(bufs, aux)],
		[21, _rad_table],
		[29, _one if frac == "" else _single(bufs, frac)],
		# Only a detector's own compaction passes touch these; an ordinary row binds the void.
		[34, _zero if list.is_empty() else bufs[String(list["idx"])]],
		[35, _zero if list.is_empty() else bufs[String(list["args"])]],
		# Heat travels with the matter that holds it, so a row reads the enthalpy of ITS OWN entry.
		[46, _single(bufs, _carried_key(String(row["substance"])))],
		# A booked channel's boundary crossings; an unbooked row writes a void pair nothing reads.
		# A signed channel books its amount leg only; the kernel never writes its heat leg.
		[48, _single(bufs, _book(channel, false))],
		[49, _single(bufs, _book(channel, true))],
		# O3 partial density, kg/m^3: zeros until a photochemical o3 channel exists to swap in.
		[56, _zero],
		# The momentum riding a mass row's exterior crossing; a signed row books through binding 48
		# and binds the void here.
		[69, _single(bufs, "bnd_void" if bool(row.get("signed", false)) else _book("mom_x", false))],
		[70, _single(bufs, "bnd_void" if bool(row.get("signed", false)) else _book("mom_y", false))],
		[71, _single(bufs, "bnd_void" if bool(row.get("signed", false)) else _book("mom_z", false))],
		# The charge riding a mass row's crossing; a signed channel books its own through binding 48.
		[79, _single(bufs, "bnd_void" if BoundaryRowsScript.BOOKED_SIGNED.has(channel)
			else _book("charge", false))],
	]
	return _uset(_pipe, entries)


## The book a channel's crossings land in. A channel this world cannot move cannot cross, so it books
## into the void pair no reduce row reads.
func _book(channel: String, heat: bool) -> String:
	var void_key: String = BoundaryRowsScript.HEAT_PREFIX + "void" if heat \
		else BoundaryRowsScript.BOOKED_PREFIX + "void"
	if not LAProcessSet.books(channel):
		return void_key
	if heat and not BoundaryRowsScript.BOOKED.has(channel):
		return void_key
	return (BoundaryRowsScript.HEAT_PREFIX if heat else BoundaryRowsScript.BOOKED_PREFIX) + channel


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
	["dilute", LATransportRecords.Flag.DILUTE],
	["relax", LATransportRecords.Flag.RELAX], ["radiogenic", LATransportRecords.Flag.RADIOGENIC]]
const NAMED: Array = [["drive", LATransportRecords.Flag.DRIVEN],
	["frac", LATransportRecords.Flag.FRACTION]]


## A substep only moves the level and its index along, so the rest of the block is built once per row,
## pass and level class per step: at thousands of substeps the encoding IS the dispatch cost.
var _pc_cache: Dictionary = {}


func _pc_at(r: int, cc: int, pass_id: int, cell_m: float, dt_s: float, sun: Vector3,
		level: int, k: int, n: int) -> PackedByteArray:
	var key: int = r * 32 + pass_id
	var pc: PackedByteArray = _pc_cache.get(key, PackedByteArray())
	if pc.is_empty():
		pc = _pc(_rows[r], cc, pass_id, cell_m, dt_s, sun, level, k, n, _row_group[r])
		_pc_cache[key] = pc
	pc.encode_u32(104, level)
	pc.encode_u32(108, k)
	pc.encode_u32(112, n)
	return pc


## transport.glsl's Params block, in its declared order.
func _pc(row: Dictionary, cc: int, pass_id: int, cell_m: float, dt_s: float,
		sun: Vector3, level: int = 0, substep_k: int = 0, substep_n: int = 1,
		act_group: int = 0) -> PackedByteArray:
	var substance: String = String(row["substance"])
	var entry: Dictionary = LASubstances.table().get(substance, {})
	var fluid: Vector2 = LATransportRecords.fluid_properties(
		int(row.get("fluid", LATransportRecords.Fluid.VACUUM)))
	# EVERY ROW PASS WALKS A LIST NOW, so the remap is unconditional.
	var flags: int = LATransportRecords.Flag.VEL if _vel_row(row) else 0
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
	pc.resize(124)
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
	pc.encode_u32(116, act_group)
	# A row carrying silicate also wakes the prologue that derives where that mineral sits.
	pc.encode_u32(120, _group_count() - 1 if String(row["channel"]) == "silicate" else NO_GROUP)
	return pc


func _filled(n: int, v: float) -> PackedByteArray:
	var a: PackedFloat32Array = PackedFloat32Array()
	a.resize(n)
	a.fill(v)
	return a.to_byte_array()
