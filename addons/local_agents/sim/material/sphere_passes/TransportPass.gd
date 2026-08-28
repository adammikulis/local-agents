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

## Dispatches one submit may hold. The device waits on a fence to read a buffer back, and a submit
## longer than that wait fails; splitting the recording changes nothing dispatched, only when.
const FLUSH_EVERY: int = 4096

## Byte offsets of the level, substep index and substep count in the Params block below: the three the
## driver rewrites per substep.
const PC_LEVEL: int = 104
const PC_K: int = 108
const PC_N: int = 112

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
	# The temporal levels are StateDerivePass's declaration: its restate walks the same sorted list this
	# pass dispatches over, and it runs at rungs where this pass does not exist.
	out.merge(ActiveScript.buffers(cc + ghost_count, group_count()))
	return out


## One slot per row group, plus the grain prologue's own LAST: it derives where a cell's loose mineral
## sits, so it is awake wherever silicate moved rather than wherever anything did.
static func group_count() -> int:
	return _grouping(LAProcessSet.transport_rows()).size() + 1


## Consecutive rows that advance on ONE time axis: the acoustic pair and the momentum rows it carries.
static func _grouping(rows: Array) -> Array:
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
	_driver.setup_transport(_plan())


## What the native driver walks: the sets, the groups and the buffers. Every ROW stays in
## LATransportRecords; nothing here restates one.
func _plan() -> Dictionary:
	var radiate: PackedInt32Array = PackedInt32Array()
	for row: Dictionary in _rows:
		radiate.append(1 if int(row["mode"]) == LATransportRecords.RADIATE else 0)
	var acoustic: PackedInt32Array = PackedInt32Array()
	var groups: Array = []
	for group: PackedInt32Array in _row_groups:
		groups.append(group)
		acoustic.append(1 if _vel_row(_rows[group[group.size() - 1]]) else 0)
	return {"pipe": _pipe, "row_sets": _sets, "row_group": _row_group, "row_radiate": radiate,
		"groups": groups, "group_acoustic": acoustic, "args": _args_rid,
		"wake_args": _wake_args_rid, "grain_set": _grain_set, "list_sets": _list_sets,
		"queue_bin": ActiveScript.QUEUE_BIN, "slots": LevelsScript.SLOTS,
		"group_count": group_count(), "flush_every": FLUSH_EVERY,
		"level_off": PC_LEVEL, "k_off": PC_K, "n_off": PC_N}


## XUV irradiance at this body, W/m^2, taken once per dispatch off the ctx the star publishes into.
var _xuv_w_m2: float = 0.0


func dispatch(_rd: RenderingDevice, cl: int, ctx: Dictionary, cc: int, groups: int) -> void:
	if not _dispatchable():
		return
	var cell_m: float = _ctx_cell_size(ctx)
	var dt_s: float = _ctx_num(ctx, "dt_s")
	var sun: Vector3 = ctx.get("sun_dir", Vector3.ZERO)
	# No sun in the ctx is no star, which is no XUV — never an assumed one.
	_xuv_w_m2 = float(ctx.get("xuv_w_m2", 0.0))
	# The equation of state, restated after every substep's gather. StateDerivePass owns the kernel, the
	# bindings and the block; this pass owns when the substep asks for it.
	_driver.run_transport(cl, _peaks, _pc_rows(cc, cell_m, dt_s, sun),
		_pc_grain(cc, cell_m, dt_s, sun), _pc_lists(cc, cell_m, dt_s, sun),
		_seed_workgroups(), groups, ctx.get("restate", {}))


## THE LISTS, before anything reads one: every cell of a world nobody has stepped yet, and every cell
## again after a CPU write no kernel saw. Workgroups over the whole box, and 0 on every other step.
func _seed_workgroups() -> int:
	if not _wake_pending or not _grain_set.is_valid():
		return 0
	_wake_pending = false
	var wide: int = maxi(_total, (ActiveScript.QUEUE_BIN + 1) * group_count())
	return int(ceil(float(wide) / 64.0))


## THE LEVEL FIELD, once per group over the cells it holds. The counting sort that turns it into a
## dispatch list is the active-cell rebuild, which the driver runs every substep.
func build_levels(cl: int, g: int, cc: int, cell_m: float, dt_s: float, sun: Vector3,
		levels: int) -> void:
	_driver.build_levels(cl, g, _pc_rows(cc, cell_m, dt_s, sun), levels)


## Every cell changed at once, from outside any kernel: the one seam a CPU writer has into the mask.
## The next step seeds every list with the whole box again, and the bubbles regrow from there.
func wake_all() -> void:
	_wake_pending = true


## THE PEAK LEVEL PER GROUP, before the step records: a submit of its own, so the loop bounds come from
## the state this step starts in rather than from a reading one step stale.
func pre_step(rd: RenderingDevice, ctx: Dictionary, cc: int, _groups: int) -> void:
	if not _dispatchable() or not _peak_rid.is_valid() or _row_groups.is_empty():
		return
	var cell_m: float = _ctx_cell_size(ctx)
	var dt_s: float = _ctx_num(ctx, "dt_s")
	rd.buffer_clear(_peak_rid, 0, _row_groups.size() * 4)
	var usets: Array = []
	var pcs: Array = []
	var wgs: PackedInt32Array = PackedInt32Array()
	var args: Array = []
	var offs: PackedInt32Array = PackedInt32Array()
	var seed: int = _seed_workgroups()
	if seed > 0:
		usets.append(_grain_set)
		pcs.append(_pc(GRAIN_ROW, cc, PASS_ACT_SEED, cell_m, dt_s, Vector3.ZERO, 0, 0, 1,
			group_count()))
		wgs.append(seed)
		args.append(RID())
		offs.append(0)
	for g in _row_groups.size():
		for gi in _row_groups[g]:
			usets.append(_sets[gi])
			pcs.append(_pc(_rows[gi], cc, PASS_LEVEL_PEAK, cell_m, dt_s, Vector3.ZERO, g, 0, 1, g))
			wgs.append(0)
			args.append(_args_rid)
			offs.append(ActiveScript.args_offset(g, 0))
	var cl: int = rd.compute_list_begin()
	_driver.run(cl, _pipe, usets, pcs, wgs, args, offs, true)
	rd.compute_list_end()
	rd.submit()
	rd.sync()
	_peaks = rd.buffer_get_data(_peak_rid, 0, _row_groups.size() * 4).to_int32_array()
	# A CELL ASKING FOR A STEP SHORTER THAN LIGHT TAKES TO CROSS IT IS NOT ASKING FOR RESOLUTION.
	# Its state is broken, no subdivision integrates it, and its group does not move this step.
	var lim: int = LevelsScript.light_level(dt_s, cell_m)
	_peak_top = 0
	for g2 in _peaks.size():
		_peak_top = maxi(_peak_top, _peaks[g2])
		if _peaks[g2] < lim:
			continue
		_peaks[g2] = -1
		push_error("TransportPass: the %s row's own cells carry a signal speed at or past light, so "
			% String(_rows[_row_groups[g2][0]]["channel"]) + "no timestep integrates them.")


## A signed per-axis momentum row, whose gather refreshes its velocity component.
static func _vel_row(row: Dictionary) -> bool:
	return row.has("axis") and bool(row.get("signed", false))


## A row of the acoustic substep group: a momentum row, or compressible matter flagged into it.
static func _group_row(row: Dictionary) -> bool:
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
	for g in mini(group_count(), args.size() / stride):
		n += args[g * stride + int(Arg.SUFFIX)]
	return float(n)


## Bindings that are just a driver buffer by name: its key to transport.glsl's binding number. ONE
## declaration of what this pass needs, so a buffer the driver never made is a named error, not a
## silent set. The level and activity names are LATemporalLevels.KEYS and LAActiveCells.KEYS.
const BINDINGS: Dictionary = {
	"nbr": 2, "solid": 3, "g_rest": 4, "vel_x": 5, "vel_y": 6, "vel_z": 7, "charge": 13, "temp": 15,
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


## One push-constant block per row per slot the driver may issue, built once per step. The driver
## rewrites only the level and the substep pair, so a substep costs no encoding at all.
func _pc_rows(cc: int, cell_m: float, dt_s: float, sun: Vector3) -> Array:
	var out: Array = []
	for _r in _rows.size():
		var t: Array = []
		t.resize(LAFieldDriver.SLOT_COUNT)
		t.fill(PackedByteArray())
		out.append(t)
	for g in _row_groups.size():
		var group: PackedInt32Array = _row_groups[g]
		var head: Dictionary = _rows[group[0]]
		var ht: Array = out[group[0]]
		ht[LAFieldDriver.SLOT_LEVEL_RESET] = _pc(head, cc, PASS_LEVEL_RESET, cell_m, dt_s, sun, 0, 0, 1, g)
		ht[LAFieldDriver.SLOT_LEVEL_RELAX] = _pc(head, cc, PASS_LEVEL_RELAX, cell_m, dt_s, sun, 0, 0, 1, g)
		ht[LAFieldDriver.SLOT_ACT_AGE] = _pc(head, cc, PASS_ACT_AGE, cell_m, dt_s, sun, 0, 0, 1, g)
		ht[LAFieldDriver.SLOT_ACT_WAKE] = _pc(head, cc, PASS_ACT_WAKE, cell_m, dt_s, sun, 0, 0, 1, g)
		ht[LAFieldDriver.SLOT_ACT_MARK] = _pc(head, cc, PASS_ACT_MARK, cell_m, dt_s, sun, 0, 0, 1, g)
		ht[LAFieldDriver.SLOT_LEVEL_SCAN] = _pc(head, cc, PASS_LEVEL_SCAN, cell_m, dt_s, sun, 0, 0, 1, g)
		ht[LAFieldDriver.SLOT_LEVEL_SORT] = _pc(head, cc, PASS_LEVEL_SORT, cell_m, dt_s, sun, 0, 0, 1, g)
		for gi in group:
			var row: Dictionary = _rows[gi]
			var rt: Array = out[gi]
			rt[LAFieldDriver.SLOT_LEVEL_SEED] = _pc(row, cc, PASS_LEVEL_SEED, cell_m, dt_s, sun, 0, 0, 1, g)
			rt[LAFieldDriver.SLOT_OUTFLOW] = _pc(row, cc, PASS_OUTFLOW, cell_m, dt_s, sun, 0, 0, 1, g)
			rt[LAFieldDriver.SLOT_GATHER] = _pc(row, cc, PASS_GATHER, cell_m, dt_s, sun, 0, 0, 1, g)
			if int(row["mode"]) == LATransportRecords.RADIATE:
				rt[LAFieldDriver.SLOT_SW] = _pc(row, cc, PASS_SW, cell_m, dt_s, sun, 0, 0, 1, g)
		# The acoustic pair rides the group's last row, so that row carrying velocity IS the test.
		var last: int = group[group.size() - 1]
		if _vel_row(_rows[last]):
			var lt: Array = out[last]
			lt[LAFieldDriver.SLOT_ACOUSTIC] = _pc(_rows[last], cc, PASS_ACOUSTIC, cell_m, dt_s, sun, 0, 0, 1, g)
			lt[LAFieldDriver.SLOT_ACOUSTIC_APPLY] = _pc(_rows[last], cc, PASS_ACOUSTIC_APPLY, cell_m,
				dt_s, sun, 0, 0, 1, g)
	return out


## The grain prologue's own blocks, plus the whole-box seed and the wake-queue reset.
func _pc_grain(cc: int, cell_m: float, dt_s: float, sun: Vector3) -> Array:
	var t: Array = []
	t.resize(LAFieldDriver.SLOT_COUNT)
	t.fill(PackedByteArray())
	if not _grain_set.is_valid():
		return t
	var gslot: int = group_count() - 1
	t[LAFieldDriver.SLOT_LEVEL_RESET] = _pc(GRAIN_ROW, cc, PASS_LEVEL_RESET, cell_m, dt_s, sun, 0, 0, 1, gslot)
	t[LAFieldDriver.SLOT_ACT_AGE] = _pc(GRAIN_ROW, cc, PASS_ACT_AGE, cell_m, dt_s, sun, 0, 0, 1, gslot)
	t[LAFieldDriver.SLOT_ACT_WAKE] = _pc(GRAIN_ROW, cc, PASS_ACT_WAKE, cell_m, dt_s, sun, 0, 0, 1, gslot)
	t[LAFieldDriver.SLOT_ACT_MARK] = _pc(GRAIN_ROW, cc, PASS_ACT_MARK, cell_m, dt_s, sun, 0, 0, 1, gslot)
	t[LAFieldDriver.SLOT_LEVEL_SCAN] = _pc(GRAIN_ROW, cc, PASS_LEVEL_SCAN, cell_m, dt_s, sun, 0, 0, 1, gslot)
	t[LAFieldDriver.SLOT_LEVEL_SORT] = _pc(GRAIN_ROW, cc, PASS_LEVEL_SORT, cell_m, dt_s, sun, 0, 0, 1, gslot)
	t[LAFieldDriver.SLOT_GRAIN] = _pc(GRAIN_ROW, cc, PASS_GRAIN, cell_m, dt_s, sun, 0, 0, 1, gslot)
	t[LAFieldDriver.SLOT_ACT_SEED] = _pc(GRAIN_ROW, cc, PASS_ACT_SEED, cell_m, dt_s, Vector3.ZERO,
		0, 0, 1, group_count())
	t[LAFieldDriver.SLOT_ACT_WAKE_RESET] = _pc(GRAIN_ROW, cc, PASS_ACT_WAKE_RESET, cell_m, dt_s, sun)
	return t


## THE DETECTOR LISTS: where the strikes and the non-finite values are. A detector looks everywhere
## because a value it has never seen can sit anywhere; no row dispatches over one.
func _pc_lists(cc: int, cell_m: float, dt_s: float, sun: Vector3) -> Array:
	var out: Array = []
	for r in _list_rows.size():
		var t: Array = []
		t.resize(LAFieldDriver.SLOT_COUNT)
		t.fill(PackedByteArray())
		t[LAFieldDriver.SLOT_LIST_RESET] = _pc(_list_rows[r], cc, PASS_LIST_RESET, cell_m, dt_s, sun)
		t[LAFieldDriver.SLOT_LIST_APPEND] = _pc(_list_rows[r], cc, PASS_LIST_APPEND, cell_m, dt_s, sun)
		t[LAFieldDriver.SLOT_LIST_ARGS] = _pc(_list_rows[r], cc, PASS_LIST_ARGS, cell_m, dt_s, sun)
		out.append(t)
	return out


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
	pc.encode_u32(PC_LEVEL, level)
	pc.encode_u32(PC_K, substep_k)
	pc.encode_u32(PC_N, substep_n)
	pc.encode_u32(116, act_group)
	# A row carrying silicate also wakes the prologue that derives where that mineral sits.
	pc.encode_u32(120, group_count() - 1 if String(row["channel"]) == "silicate" else NO_GROUP)
	return pc


func _filled(n: int, v: float) -> PackedByteArray:
	var a: PackedFloat32Array = PackedFloat32Array()
	a.resize(n)
	a.fill(v)
	return a.to_byte_array()
