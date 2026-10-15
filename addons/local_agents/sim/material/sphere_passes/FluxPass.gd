extends "res://addons/local_agents/sim/material/sphere_passes/SpherePass.gd"

## Everything that crosses a face, through one kernel: flux.glsl states each face once, then runs
## LATransportRecords row by row over it.

const KERNEL_PATH: String = "res://addons/local_agents/sim/material/kernels3d/flux.glsl"
const MOVES_STATE: bool = true   # crossings move matter and energy

const BoundaryRowsScript: GDScript = preload("res://addons/local_agents/sim/material/reduce/BoundaryRows.gd")
const LevelsScript: GDScript = preload("res://addons/local_agents/sim/material/sphere_passes/TemporalLevels.gd")
const ActiveScript: GDScript = preload("res://addons/local_agents/sim/material/sphere_passes/ActiveCells.gd")


## List-args layout: 0-2 the indirect uvec3, 3 the atomic list length, 4 the sorted offset, 5 the
## scatter cursor, 6 the suffix count at this level or finer, SLOTS the element count.
enum Arg { GROUPS_X = 0, GROUPS_Y = 1, GROUPS_Z = 2, LIST_COUNT = 3, OFFSET = 4, CURSOR = 5,
	SUFFIX = 6, SLOTS = 8 }

## The grain prologue carries mineral grains, so the Stokes law reads silicate's density off `substance`.
const GRAIN_ROW: Dictionary = {"channel": "silicate", "substance": "silicate",
	"mode": LATransportRecords.POTENTIAL}

## The three legs momentum crosses a boundary on.
const MOMENTUM_BOOKS: PackedStringArray = ["mom_x", "mom_y", "mom_z"]

var _pipe: RID = RID()
var _level_rid: RID = RID()


## Records that advance together on one time axis; a solitary record is its own group.
var _row_groups: Array = []
## Per group: the finest temporal level its own state asked for, read back before the step records;
## -1 = a state no timestep integrates. `_peak_top` is the finest any group asked, for the drain.
var _peaks: PackedInt32Array = PackedInt32Array()
var _peak_top: int = 0
var _args_rid: RID = RID()
var _peak_rid: RID = RID()
var _wake_args_rid: RID = RID()
## Interior cells plus the ghost tail.
var _total: int = 0
## Something outside this pass wrote the field, so the next step seeds every list with the whole box.
var _wake_pending: bool = true
## Per record: its uniform set. An invalid entry is a record whose buffers the driver has not got.
var _sets: Array = []
var _rows: Array = []
## Pass-owned scratch, binding to buffer: the face state and each record's own per-face flux, the
## RADIATE march's emissivity, beam share and reflected pair, and the mixture's eddy viscosity.
var _scr: Dictionary = {}
## resist 0 and aux 1 for a record that names neither.
var _zero: RID = RID()
var _one: RID = RID()
## Enthalpy of transported enthalpy: none, so a record moving `e_j_m3` carries this zero buffer.
var _no_h: RID = RID()
## Band edges, absorption coefficients and the Planck CDF the RADIATE record reads.
var _rad_table: RID = RID()
var _band_count: int = 0
## The grain prologue's uniform set.
var _grain_set: RID = RID()
## Per LATransportRecords.lists() entry: its synthetic record, uniform set, and args/idx RIDs.
var _list_rows: Array = []
var _list_sets: Array = []
var _list_args_rid: Array = []
var _list_idx_rid: Array = []


## The TF_EFIELD record's electric-field outputs (driver-owned so ReducePass can read them), the
## boundary books, and each list's compacted-index, membership-flag and indirect-args buffers.
func _buffers(cc: int) -> Dictionary:
	var out: Dictionary = {"col_e": cc, "strike": cc, "radiogenic": cc, "sw_space": cc, "rad_residual": cc,
		"bnd_void": cc, "bnd_h_void": cc, "rim_ghost": cc, "rim_w": cc}
	for ch in LAProcessSet.booked():
		out[BoundaryRowsScript.BOOKED_PREFIX + String(ch)] = cc
		if BoundaryRowsScript.BOOKED.has(ch):
			out[BoundaryRowsScript.HEAT_PREFIX + String(ch)] = cc
	for lrow: Dictionary in LATransportRecords.lists():
		var keys: Dictionary = LATransportRecords.list_buffers(String(lrow["label"]))
		out[String(keys["idx"])] = cc
		out[String(keys["args"])] = {"n": int(Arg.SLOTS), "indirect": true}
	# The temporal levels are StateDerivePass's declaration: its restate walks the same sorted list
	# this pass dispatches over, and it runs at rungs where this pass does not exist.
	out.merge(ActiveScript.buffers(cc + ghost_count, group_count()))
	return out


## One slot per record group, plus the grain prologue's own LAST: it derives where a cell's loose
## mineral sits, so it is awake wherever silicate moved rather than wherever anything did.
static func group_count() -> int:
	return LAFieldDriver.transport_group_count(LAProcessSet.transport_rows())


## Consecutive records that advance on ONE time axis: the acoustic set and the momentum that closes it.
func _setup(bufs: Dictionary, cc: int) -> void:
	_pipe = _kernel(KERNEL_PATH)
	_rows = LAProcessSet.transport_rows()
	_row_groups = LAFieldDriver.transport_groups(_rows)
	_peaks.resize(_row_groups.size())
	_args_rid = _single(bufs, LevelsScript.KEYS.args)
	_peak_rid = _single(bufs, LevelsScript.KEYS.peak)
	_level_rid = _single(bufs, LevelsScript.KEYS.level)
	_wake_args_rid = _single(bufs, ActiveScript.KEYS.wake_args)
	_total = cc + ghost_count

	# Ghost tail cells are read by the interior cells beside them, so every per-cell buffer the
	# kernel indexes carries the tail.
	var tc: int = cc + ghost_count
	for i in SCRATCH.size():
		_scr[i] = _scratch(face_count if i < FACE_SCRATCH else tc)
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
	_driver.setup_transport(_plan(cc))


## What the native driver walks: the sets, the groups and the buffers. Every RECORD stays in
## LATransportRecords; nothing here restates one.
func _plan(cc: int) -> Dictionary:
	return {"pipe": _pipe, "rows": _rows, "row_sets": _sets,
		"args": _args_rid,
		"wake_args": _wake_args_rid, "grain_set": _grain_set, "list_sets": _list_sets,
		"queue_bin": ActiveScript.QUEUE_BIN, "slots": LevelsScript.SLOTS,
		"cell_count": cc, "total_count": _total,
		"band_count": _band_count, "grain_record": GRAIN_ROW, "list_records": _list_rows}


func _step(ctx: Dictionary) -> Dictionary:
	return {"dt_s": _ctx_num(ctx, "dt_s"), "sun": ctx.get("sun_dir", Vector3.ZERO),
		"xuv_w_m2": float(ctx.get("xuv_w_m2", 0.0)), "phi_datum": float(ctx.get("phi_datum", 0.0))}


func dispatch(_rd: RenderingDevice, ctx: Dictionary, _cc: int, groups: int) -> void:
	if not _dispatchable():
		return
	var blocks: Dictionary = _driver.transport_blocks(_step(ctx))
	_driver.run_transport(_peaks, blocks["rows"], blocks["grain"], blocks["lists"],
		_seed_workgroups(), groups, ctx.get("restate", {}))


func build_levels(g: int, _cc: int, dt_s: float, sun: Vector3, levels: int) -> void:
	_driver.build_levels(g, _driver.transport_blocks({"dt_s": dt_s, "sun": sun})["rows"], levels)


## Every cell changed at once, from outside any kernel: the one seam a CPU writer has into the mask.
## The next step seeds every list with the whole box again, and the bubbles regrow from there.
func wake_all() -> void:
	_wake_pending = true


## THE PEAK LEVEL PER GROUP, before the step records: a submit of its own, so the loop bounds come
## from the state this step starts in rather than from a reading one step stale.
func pre_step(rd: RenderingDevice, ctx: Dictionary, cc: int, _groups: int) -> void:
	if not _dispatchable() or not _peak_rid.is_valid() or _row_groups.is_empty():
		return
	var dt_s: float = _ctx_num(ctx, "dt_s")
	rd.buffer_clear(_peak_rid, 0, _row_groups.size() * 4)
	var blocks: Dictionary = _driver.transport_blocks(_step(ctx))
	var usets: Array = []
	var pcs: Array = []
	var args: Array = []
	var offs: PackedInt32Array = PackedInt32Array()
	var keys: PackedStringArray = PackedStringArray()
	for g in _row_groups.size():
		for gi in _row_groups[g]:
			if not LAProcessSet.is_active("transport", String(_rows[gi].get("label", ""))):
				continue
			usets.append(_sets[gi])
			pcs.append(_driver.peak_block(gi, g, _step(ctx)))
			args.append(_args_rid)
			offs.append(ActiveScript.args_offset(g, 0))
			keys.append("%s/level_peak/%d" % [_label(), gi])
	var seed: int = _seed_workgroups()
	_driver.open()
	if seed > 0:
		_driver.run(_pipe, [_grain_set], [blocks["grain"][LAFieldDriver.SLOT_ACT_SEED]], PackedInt32Array([seed]), [], PackedInt32Array(), true,
			PackedStringArray([_label() + "/act_seed"]))
	_driver.run(_pipe, usets, pcs, PackedInt32Array(), args, offs, true, keys)
	_driver.close()
	_peaks = rd.buffer_get_data(_peak_rid, 0, _row_groups.size() * 4).to_int32_array()
	# A CELL ASKING FOR A STEP SHORTER THAN LIGHT TAKES TO CROSS IT IS NOT ASKING FOR RESOLUTION.
	# Its state is broken, no subdivision integrates it, and its group does not move this step.
	# The FINEST cell bounds it: light crosses a small cell in less time than a large one.
	var lim: int = LevelsScript.light_level(dt_s, _ctx_num(ctx, "cell_size_min"))
	_peak_top = 0
	for g2 in _peaks.size():
		_peak_top = maxi(_peak_top, _peaks[g2])
		if _peaks[g2] < lim:
			continue
		_peaks[g2] = -1
		var lv: PackedInt32Array = rd.buffer_get_data(_level_rid, 0, cc * 4).to_int32_array()
		var at: int = 0
		for i in lv.size(): at = i if lv[i] > lv[at] else at
		push_error("FluxPass: the %s record's own cells carry a signal speed at or past light, so "
			% String(_rows[_row_groups[g2][0]]["channel"]) + "no timestep integrates them (cell %d)." % at)


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


## Pass-owned scratch: the first FACE_SCRATCH ride a face, the rest are per cell.
const SCRATCH: PackedStringArray = ["flux_face_u", "flux_fp_star", "flux_face_uw", "flux_fpw_star",
	"flux_send", "flux_x_amt", "flux_x_h", "flux_x_q",
	"flux_lw_emis", "flux_sw_absorbed", "flux_sw_keep", "flux_sw_src", "flux_nu_t", "flux_w_top",
	"flux_dm_x", "flux_dm_y", "flux_dm_z"]
const FACE_SCRATCH: int = 8


## The uniform set for one record, or RID() when a buffer it names does not exist.
func _row_set(bufs: Dictionary, row: Dictionary) -> RID:
	var channel: String = String(row["channel"])
	var drive: String = String(row.get("drive", ""))
	var resist: String = String(row.get("resist", ""))
	var aux: String = String(row.get("aux", ""))
	var frac: String = String(row.get("frac", ""))
	var moves_enthalpy: bool = int(row["mode"]) in [LATransportRecords.CONDUCT, LATransportRecords.RADIATE]
	# Mass does not move without its heat, so the enthalpy field is required of every record carrying mass.
	# The detector-list buffers a synthetic record compacts into; empty for an ordinary record.
	var list: Dictionary = LATransportRecords.list_buffers(String(row.get("list", "")))
	var amount: RID = _single(bufs, channel)
	var own: Dictionary = {
		"flux_amount": amount,
		"flux_energy": _single(bufs, "e_lith_j_m3" if moves_enthalpy and channel == "e_j_m3"
			else "e_j_m3"),
		"flux_resist": _zero if resist == "" else _single(bufs, resist),
		"flux_drive": amount if drive == "" else _single(bufs, drive),
		"flux_aux": _one if aux == "" else _single(bufs, aux),
		"flux_rad_table": _rad_table,
		"flux_frac": _one if frac == "" else _single(bufs, frac),
		# Only a detector's own compaction passes touch these; an ordinary record binds the void.
		"active_idx": _zero if list.is_empty() else _single(bufs, String(list["idx"])),
		"active_args": _zero if list.is_empty() else _single(bufs, String(list["args"])),
		# Heat travels with the matter that holds it, so a record reads the enthalpy of ITS OWN entry.
		"flux_h_carried": _single(bufs, _carried_key(String(row["substance"]), frac)),
		# A booked channel's boundary crossings; an unbooked record writes a void pair nothing reads.
		"flux_bnd_amt": _single(bufs, _book(channel, false)),
		"flux_bnd_h": _single(bufs, _book(channel, true)),
		# O3 partial density, kg/m^3: zeros until a photochemical o3 channel exists to swap in.
		"flux_o3": _zero,
		# The momentum riding a crossing, on its own three legs.
		"flux_bnd_mom_x": _single(bufs, _mom_book("mom_x")),
		"flux_bnd_mom_y": _single(bufs, _mom_book("mom_y")),
		"flux_bnd_mom_z": _single(bufs, _mom_book("mom_z")),
		# The charge riding a crossing; the charge channel books its own through flux_bnd_amt.
		"flux_bnd_q": _single(bufs, "bnd_void" if channel == "charge" else _book("charge", false))}
	for i in SCRATCH.size():
		own[SCRATCH[i]] = _scr[i]
	return _uset(_pipe, LABindings.set_for("flux.glsl", bufs, own))


## The book a channel's crossings land in. A channel this world cannot move cannot cross, and momentum
## books on its own three legs, so both take the void pair no reduce row reads.
func _book(channel: String, heat: bool) -> String:
	var void_key: String = BoundaryRowsScript.HEAT_PREFIX + "void" if heat \
		else BoundaryRowsScript.BOOKED_PREFIX + "void"
	if MOMENTUM_BOOKS.has(channel) or not LAProcessSet.books(channel):
		return void_key
	if heat and not BoundaryRowsScript.BOOKED.has(channel):
		return void_key
	return (BoundaryRowsScript.HEAT_PREFIX if heat else BoundaryRowsScript.BOOKED_PREFIX) + channel


## One momentum leg's book, or the void where this world books no momentum.
func _mom_book(axis: String) -> String:
	if not LAProcessSet.books(axis):
		return BoundaryRowsScript.BOOKED_PREFIX + "void"
	return BoundaryRowsScript.BOOKED_PREFIX + axis


## The buffer holding the enthalpy of the mixture entry a substance's heat sits in.
func _carried_key(substance: String, frac: String = "") -> String:
	var entry: int = LAMatterChannels.entry_of(substance)
	if entry == LAMatterChannels.Entry.H2O:
		return "h_h2o_vap" if frac == "h2o_vapour" else "h_h2o"
	return "h_silicate" if entry == LAMatterChannels.Entry.SILICATE else "h_sensible"


func _seed_workgroups() -> int:
	if not _wake_pending or not _grain_set.is_valid():
		return 0
	_wake_pending = false
	var wide: int = maxi(_total, (ActiveScript.QUEUE_BIN + 1) * group_count())
	return int(ceil(float(wide) / 64.0))

func _filled(n: int, v: float) -> PackedByteArray:
	var a: PackedFloat32Array = PackedFloat32Array()
	a.resize(n)
	a.fill(v)
	return a.to_byte_array()
