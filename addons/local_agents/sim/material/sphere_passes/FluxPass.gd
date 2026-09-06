extends "res://addons/local_agents/sim/material/sphere_passes/SpherePass.gd"

## Everything that crosses a face, through one kernel: flux.glsl states each face once, then runs
## LATransportRecords row by row over it.

const KERNEL_PATH: String = "res://addons/local_agents/sim/material/kernels3d/flux.glsl"
const MOVES_STATE: bool = true   # crossings move matter and energy

const BoundaryRowsScript: GDScript = preload("res://addons/local_agents/sim/material/reduce/BoundaryRows.gd")
const ActiveScript: GDScript = preload("res://addons/local_agents/sim/material/sphere_passes/ActiveCells.gd")

## The Helmholtz whose solution is the step's acoustic pressure. Assembled on the device, converged
## by conjugate gradient in the extension, exactly as the gravity solve is.
const HELMHOLTZ_PATH: String = "res://addons/local_agents/sim/material/kernels3d/pressure_helmholtz.glsl"
const HZ_MODE_ASSEMBLE: int = 0
## Residual, as a fraction of its own source, every acoustic solve converges to, and its iteration bound.
const HZ_RESIDUAL_TOLERANCE: float = 1.0e-6
const HZ_MAX_ITERATIONS: int = 4000

## Dispatch tags: the flux and apply halves, the grain prologue, the detector compaction, the
## reflected-shortwave march, the face predictor, the momentum close and the active list.
enum { PASS_FLUX, PASS_APPLY, PASS_GRAIN, PASS_LIST_RESET, PASS_LIST_APPEND, PASS_LIST_ARGS,
	PASS_SW, PASS_FACE, PASS_MOMENTUM,
	PASS_UNUSED_9, PASS_UNUSED_10, PASS_UNUSED_11, PASS_SCAN,
	PASS_COMPACT, PASS_STEP_DT,
	PASS_ACT_AGE, PASS_ACT_WAKE, PASS_ACT_MARK, PASS_ACT_WAKE_RESET, PASS_ACT_SEED }

## flux.glsl's ACT_NO_GROUP: this record's crossings wake no second group.
const NO_GROUP: int = 0xffffffff

## List-args layout: 0-2 the indirect uvec3, 3 the atomic queue length, 4 the offset, 5 the
## cursor, 6 the cells the list holds, SLOTS the element count.
enum Arg { GROUPS_X = 0, GROUPS_Y = 1, GROUPS_Z = 2, LIST_COUNT = 3, OFFSET = 4, CURSOR = 5,
	LISTED = 6, SLOTS = 8 }

## The grain prologue carries mineral grains, so the Stokes law reads silicate's density off `substance`.
const GRAIN_ROW: Dictionary = {"channel": "silicate", "substance": "silicate",
	"mode": LATransportRecords.POTENTIAL}

## The three legs momentum crosses a boundary on.
const MOMENTUM_BOOKS: PackedStringArray = ["mom_x", "mom_y", "mom_z"]

var _pipe: RID = RID()
var _hz_pipe: RID = RID()
var _hz_set: RID = RID()
var _hz_comp_rid: RID = RID()
var _hz_rhs_rid: RID = RID()
var _hz_p_rid: RID = RID()
var _hz_cond_rid: RID = RID()
var _slot_off_rid: RID = RID()
var _nbr_rid: RID = RID()
var _cc: int = 0
var _hz_residual: float = 0.0
var _hz_iterations: int = 0

## One submit holds ONE row: the device's fence wait is finite, and a planet-size frame in one
## submit outran it.
const FLUSH_EVERY: int = 0

const PC_BYTES: int = 84

## Records that advance together on one time axis; a solitary record is its own group.
var _row_groups: Array = []
## The step the listed cells afford, seconds: the shortest any row group asked for, read back before
## the step records. INF where no row's own closure constrains it.
var _step_dt_s: float = INF
## The step this pass last published: what the world ran on, not the bound the box states before it.
var _dt_taken: float = 0.0
var _args_rid: RID = RID()
var _step_dt_rid: RID = RID()
var _wake_args_rid: RID = RID()
## Interior cells plus the ghost tail, and the record -> its group slot.
var _total: int = 0
var _row_group: PackedInt32Array = PackedInt32Array()
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
	# THE ACOUSTIC SOLVE'S OWN THREE FIELDS. The pressure is read by every cell's neighbours, ghost
	# tail included, where it stands at the vacuum's zero.
	out["hz_comp"] = cc
	out["hz_rhs"] = cc
	out["hz_p"] = cc + ghost_count
	return out


## One slot per record group, plus the grain prologue's own LAST: it derives where a cell's loose
## mineral sits, so it is awake wherever silicate moved rather than wherever anything did.
static func group_count() -> int:
	return _grouping(LAProcessSet.transport_rows()).size() + 1


## Consecutive records that advance together: the acoustic set and the momentum that closes it.
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
	_hz_pipe = _kernel(HELMHOLTZ_PATH)
	_rows = LAProcessSet.transport_rows()
	_row_groups = _grouping(_rows)
	_args_rid = _single(bufs, ActiveScript.KEYS.args)
	_step_dt_rid = _single(bufs, ActiveScript.KEYS.step_dt)
	_cc = cc
	_slot_off_rid = _single(bufs, "slot_off")
	_nbr_rid = _single(bufs, "nbr")
	_hz_comp_rid = _single(bufs, "hz_comp")
	_hz_rhs_rid = _single(bufs, "hz_rhs")
	_hz_p_rid = _single(bufs, "hz_p")
	_wake_args_rid = _single(bufs, ActiveScript.KEYS.wake_args)
	_total = cc + ghost_count
	_row_group.resize(_rows.size())
	for g in _row_groups.size():
		for gi in _row_groups[g]:
			_row_group[gi] = g

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
	_hz_cond_rid = _scr[SCRATCH.find("hz_cond")]
	_hz_set = _uset(_hz_pipe, LABindings.set_for("pressure_helmholtz.glsl", bufs, {
		"hz_comp": _hz_comp_rid, "hz_rhs": _hz_rhs_rid, "hz_p": _hz_p_rid,
		"hz_flux": _scr[SCRATCH.find("hz_flux")], "hz_cond": _hz_cond_rid}))
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


## What the native driver walks: the sets, the groups and the buffers. Every RECORD stays in
## LATransportRecords; nothing here restates one.
func _plan() -> Dictionary:
	var radiate: PackedInt32Array = PackedInt32Array()
	for row: Dictionary in _rows:
		radiate.append(1 if int(row["mode"]) == LATransportRecords.RADIATE else 0)
	return {"pipe": _pipe, "rows": _rows, "row_sets": _sets, "row_group": _row_group,
		"row_radiate": radiate, "groups": _row_groups, "args": _args_rid,
		"wake_args": _wake_args_rid, "grain_set": _grain_set, "list_sets": _list_sets,
		"hz_pipe": _hz_pipe, "hz_set": _hz_set, "slots": ActiveScript.SLOTS,
		"hz_comp": _hz_comp_rid, "hz_cond": _hz_cond_rid, "hz_rhs": _hz_rhs_rid, "hz_p": _hz_p_rid,
		"hz_flux": _scr[SCRATCH.find("hz_flux")],
		"slot_off": _slot_off_rid, "nbr": _nbr_rid, "cell_count": _cc,
		"hz_cell_bytes": _cc * 4, "hz_p_bytes": (_cc + ghost_count) * 4,
		"hz_face_bytes": face_count * 4,
		"hz_tol": HZ_RESIDUAL_TOLERANCE, "hz_max_iter": HZ_MAX_ITERATIONS,
		"group_count": group_count(), "flush_every": FLUSH_EVERY}


## XUV irradiance at this body, W/m^2, taken once per dispatch off the ctx the star publishes into.
var _xuv_w_m2: float = 0.0
var _phi_datum: float = 0.0             # J/kg, la_phi's zero against infinity
var _grav_self: float = 1.0


func dispatch(_rd: RenderingDevice, cl: int, ctx: Dictionary, cc: int, groups: int) -> void:
	if not _dispatchable():
		return
	var dt_s: float = _ctx_num(ctx, "dt_s")
	var sun: Vector3 = ctx.get("sun_dir", Vector3.ZERO)
	# No sun in the ctx is no star, which is no XUV — never an assumed one.
	_xuv_w_m2 = float(ctx.get("xuv_w_m2", 0.0))
	_phi_datum = float(ctx.get("phi_datum", 0.0))
	_grav_self = float(ctx.get("gravity_self", 1.0))
	# The equation of state, restated after the step's crossings. StateDerivePass owns the kernel, the
	# bindings and the block; this pass owns when the step asks for it.
	_driver.run_transport(cl, _pc_rows(cc, dt_s, sun),
		_pc_grain(cc, dt_s, sun), _pc_lists(cc, dt_s, sun),
		_seed_workgroups(), groups, ctx.get("restate", {}), _hz_push(cc, dt_s))
	var hz: Dictionary = _driver.acoustic_reading()
	_hz_residual = float(hz["residual_rel"])
	_hz_iterations = int(hz["iterations"])
	var bad: int = int(hz["nonfinite_cell"])
	if bad >= 0:
		push_error("ACOUSTIC_ROW_NONFINITE: cell %d states a compliance, a source or a pressure that is "
			% bad + "not a number, so the step it opened in is already broken and nothing solves it.")
		return
	if _hz_residual > HZ_RESIDUAL_TOLERANCE:
		push_error(("The acoustic solve did not converge: the Helmholtz residual is still %f of its "
			+ "source, so the momentum this step closes on is not the one continuity asks for.")
			% _hz_residual)


## THE LISTS, before anything reads one: every cell of a world nobody has stepped yet, and every cell
## again after a CPU write no kernel saw. Workgroups over the whole box, and 0 on every other step.
func _seed_workgroups() -> int:
	if not _wake_pending or not _grain_set.is_valid():
		return 0
	_wake_pending = false
	var wide: int = maxi(_total, group_count())
	return int(ceil(float(wide) / 64.0))


## Every cell changed at once, from outside any kernel: the one seam a CPU writer has into the mask.
## The next step seeds every list with the whole box again, and the bubbles regrow from there.
func wake_all() -> void:
	_wake_pending = true


## THE STEP THE WORLD AFFORDS, before the step records: a submit of its own, so what it reads is the
## state this step starts in. Every listed cell states the seconds its own explicit closures can be
## integrated over; the shortest is the field step, and `dt_s` goes into the ctx every pass reads.
func pre_step(_rd2: RenderingDevice, ctx: Dictionary, cc: int, _groups: int) -> void:
	if not _dispatchable() or not _step_dt_rid.is_valid() or _row_groups.is_empty():
		return
	var dt_prev: float = _ctx_num(ctx, "dt_s")
	_step_dt_s = _driver.step_seconds(_step_dt_rid, _pc_rows(cc, dt_prev, Vector3.ZERO),
		_pc_grain(cc, dt_prev, Vector3.ZERO), _seed_workgroups())
	# The box's own bound and the rows' are one step: whichever is shorter.
	var fall: float = LAMaterialFieldSphereStep3D.seconds_per_step()
	var dt: float = _step_dt_s if fall <= 0.0 else minf(_step_dt_s, fall)
	if dt > 0.0 and is_finite(dt):
		_dt_taken = dt
		LAMaterialFieldSphereStep3D.publish_step_seconds(dt)
		ctx["dt_s"] = dt


## pressure_helmholtz.glsl's Params block: the cells, the mode and the step it assembles for.
func _hz_push(cc: int, dt_s: float) -> PackedByteArray:
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(12)
	pc.encode_u32(0, cc)
	pc.encode_u32(4, HZ_MODE_ASSEMBLE)
	pc.encode_float(8, dt_s)
	return pc


## The record that closes a group with the interface pressure and the body impulse.
static func _vel_row(row: Dictionary) -> bool:
	return bool(row.get("momentum", false))


## A record of the acoustic substep group: the momentum close, or compressible matter flagged into it.
static func _group_row(row: Dictionary) -> bool:
	return _vel_row(row) or bool(row.get("acoustic", false))


## Cells each list holds after the last step; an `emit_idx` list also returns its occupied prefix.
func _drain(rd: RenderingDevice) -> Dictionary:
	var out: Dictionary = {"field_dt_s": _dt_taken,
		"acoustic_residual_rel": _hz_residual, "acoustic_cg_iterations": float(_hz_iterations),
		"active_cells": _active_cells(rd)}
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
	var stride: int = int(Arg.SLOTS)
	var n: int = 0
	for g in mini(group_count(), args.size() / stride):
		n += args[g * stride + int(Arg.LISTED)]
	return float(n)


## Pass-owned scratch: the first FACE_SCRATCH ride a face, the rest are per cell.
const SCRATCH: PackedStringArray = ["flux_face_u", "flux_fp_star", "flux_face_uw", "flux_fpw_star",
	"flux_send", "flux_x_amt", "flux_x_h", "flux_x_q", "hz_flux", "hz_cond",
	"flux_lw_emis", "flux_sw_absorbed", "flux_sw_keep", "flux_sw_src", "flux_nu_t", "flux_w_top"]
const FACE_SCRATCH: int = 10


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


# --- push constant ----------------------------------------------------------------------------------------

## Record keys the kernel unpacks as flags: a switch it reads as a bool, and a key it reads as
## named-or-not.
const SWITCHES: Array = [["settle", LATransportRecords.Flag.SETTLE],
	["efield", LATransportRecords.Flag.EFIELD], ["dilute", LATransportRecords.Flag.DILUTE],
	["relax", LATransportRecords.Flag.RELAX], ["radiogenic", LATransportRecords.Flag.RADIOGENIC],
	["lattice", LATransportRecords.Flag.LATTICE]]
const NAMED: Array = [["frac", LATransportRecords.Flag.FRACTION]]


## One push-constant block per record per slot the driver may issue, built once per step. The driver
## rewrites only the level and the substep pair, so a substep costs no encoding at all.
func _pc_rows(cc: int, dt_s: float, sun: Vector3) -> Array:
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
		ht[LAFieldDriver.SLOT_ACT_AGE] = _pc(head, cc, PASS_ACT_AGE, dt_s, sun, g)
		ht[LAFieldDriver.SLOT_ACT_WAKE] = _pc(head, cc, PASS_ACT_WAKE, dt_s, sun, g)
		ht[LAFieldDriver.SLOT_ACT_MARK] = _pc(head, cc, PASS_ACT_MARK, dt_s, sun, g)
		ht[LAFieldDriver.SLOT_SCAN] = _pc(head, cc, PASS_SCAN, dt_s, sun, g)
		ht[LAFieldDriver.SLOT_COMPACT] = _pc(head, cc, PASS_COMPACT, dt_s, sun, g)
		# ONE FACE PREDICTOR PER STEP, on the group's head, before any record reads a face.
		ht[LAFieldDriver.SLOT_FACE] = _pc(head, cc, PASS_FACE, dt_s, sun, g)
		for gi in group:
			var row: Dictionary = _rows[gi]
			var rt: Array = out[gi]
			rt[LAFieldDriver.SLOT_STEP_DT] = _pc(row, cc, PASS_STEP_DT, dt_s, sun, g)
			# The momentum record moves no matter of its own: it has no flux or apply half.
			if not _vel_row(row):
				rt[LAFieldDriver.SLOT_OUTFLOW] = _pc(row, cc, PASS_FLUX, dt_s, sun, g)
				rt[LAFieldDriver.SLOT_GATHER] = _pc(row, cc, PASS_APPLY, dt_s, sun, g)
			if int(row["mode"]) == LATransportRecords.RADIATE:
				rt[LAFieldDriver.SLOT_SW] = _pc(row, cc, PASS_SW, dt_s, sun, g)
		# The pressure and the body impulse close the group, on the record that carries them.
		var last: int = group[group.size() - 1]
		if _vel_row(_rows[last]):
			out[last][LAFieldDriver.SLOT_MOMENTUM] = _pc(_rows[last], cc, PASS_MOMENTUM, dt_s, sun, g)
	return out


## The grain prologue's own blocks, plus the whole-box seed and the wake-queue reset.
func _pc_grain(cc: int, dt_s: float, sun: Vector3) -> Array:
	var t: Array = []
	t.resize(LAFieldDriver.SLOT_COUNT)
	t.fill(PackedByteArray())
	if not _grain_set.is_valid():
		return t
	var gslot: int = group_count() - 1
	t[LAFieldDriver.SLOT_ACT_AGE] = _pc(GRAIN_ROW, cc, PASS_ACT_AGE, dt_s, sun, gslot)
	t[LAFieldDriver.SLOT_ACT_WAKE] = _pc(GRAIN_ROW, cc, PASS_ACT_WAKE, dt_s, sun, gslot)
	t[LAFieldDriver.SLOT_ACT_MARK] = _pc(GRAIN_ROW, cc, PASS_ACT_MARK, dt_s, sun, gslot)
	t[LAFieldDriver.SLOT_SCAN] = _pc(GRAIN_ROW, cc, PASS_SCAN, dt_s, sun, gslot)
	t[LAFieldDriver.SLOT_COMPACT] = _pc(GRAIN_ROW, cc, PASS_COMPACT, dt_s, sun, gslot)
	t[LAFieldDriver.SLOT_GRAIN] = _pc(GRAIN_ROW, cc, PASS_GRAIN, dt_s, sun, gslot)
	t[LAFieldDriver.SLOT_ACT_SEED] = _pc(GRAIN_ROW, cc, PASS_ACT_SEED, dt_s, Vector3.ZERO, group_count())
	t[LAFieldDriver.SLOT_ACT_WAKE_RESET] = _pc(GRAIN_ROW, cc, PASS_ACT_WAKE_RESET, dt_s, sun)
	return t


## THE DETECTOR LISTS: where the strikes and the non-finite values are. A detector looks everywhere
## because a value it has never seen can sit anywhere; no record dispatches over one.
func _pc_lists(cc: int, dt_s: float, sun: Vector3) -> Array:
	var out: Array = []
	for r in _list_rows.size():
		var t: Array = []
		t.resize(LAFieldDriver.SLOT_COUNT)
		t.fill(PackedByteArray())
		t[LAFieldDriver.SLOT_LIST_RESET] = _pc(_list_rows[r], cc, PASS_LIST_RESET, dt_s, sun)
		t[LAFieldDriver.SLOT_LIST_APPEND] = _pc(_list_rows[r], cc, PASS_LIST_APPEND, dt_s, sun)
		t[LAFieldDriver.SLOT_LIST_ARGS] = _pc(_list_rows[r], cc, PASS_LIST_ARGS, dt_s, sun)
		out.append(t)
	return out


## flux.glsl's Params block, in its declared order.
func _pc(row: Dictionary, cc: int, pass_id: int, dt_s: float,
		sun: Vector3, act_group: int = 0) -> PackedByteArray:
	var substance: String = String(row["substance"])
	var entry: Dictionary = LASubstances.table().get(substance, {})
	var flags: int = LATransportRecords.Flag.VEL if _vel_row(row) else 0
	for pair: Array in SWITCHES:
		if bool(row.get(String(pair[0]), false)):
			flags |= int(pair[1])
	for pair2: Array in NAMED:
		if String(row.get(String(pair2[0]), "")) != "":
			flags |= int(pair2[1])
	# The record whose amount IS enthalpy books joules on both boundary legs.
	if int(row["mode"]) in [LATransportRecords.CONDUCT, LATransportRecords.RADIATE]:
		flags |= LATransportRecords.Flag.ENERGY
	flags |= LATransportRecords.Flag.WATER if int(row.get("fluid", LATransportRecords.Fluid.VACUUM)) == LATransportRecords.Fluid.WATER else 0
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(PC_BYTES)
	pc.encode_u32(0, cc)
	pc.encode_u32(4, pass_id)
	pc.encode_u32(8, int(row["mode"]))
	pc.encode_u32(12, int(row.get("law", LATransportRecords.Law.NONE)))
	pc.encode_u32(16, _band_count)
	pc.encode_u32(20, flags)
	pc.encode_float(24, dt_s)
	pc.encode_float(28, float(row.get("repose_tan", 0.0)))
	var max_fill: float = LATransportRecords.max_fill(substance) if substance != "" else INF
	pc.encode_float(32, float(entry.get("density", 0.0)))
	# Enthalpy and momentum are not matter occupying volume, so no cell is ever full of them.
	pc.encode_float(36, max_fill)
	# Seed diameter for cells whose own grain field is unset; the cell's value wins wherever it has one.
	pc.encode_float(40, LAPhysical.GRAIN_D_UPLAND_M)
	pc.encode_float(44, sun.x)
	pc.encode_float(48, sun.y)
	pc.encode_float(52, sun.z)
	# J/m^3/K one mol/m^3 of the substance contributes to the sensible entry (molar mass times specific
	# heat); 0 for a substance on a phase ladder, whose entry is the channel itself.
	pc.encode_float(56, float(entry.get("molar_mass", 0.0)) * LAMatterChannels.specific_heat(substance))
	pc.encode_u32(60, cc + ghost_count)
	# XUV irradiance AT THIS BODY, already distance-corrected by the star that emitted it; the zenith
	# cosine is what still scales it in-kernel.
	pc.encode_float(64, _xuv_w_m2)
	pc.encode_u32(68, act_group)
	# A record carrying silicate also wakes the prologue that derives where that mineral sits.
	pc.encode_u32(72, group_count() - 1 if String(row["channel"]) == "silicate" else NO_GROUP)
	pc.encode_float(76, _phi_datum)
	pc.encode_float(80, _grav_self)
	return pc


func _filled(n: int, v: float) -> PackedByteArray:
	var a: PackedFloat32Array = PackedFloat32Array()
	a.resize(n)
	a.fill(v)
	return a.to_byte_array()
