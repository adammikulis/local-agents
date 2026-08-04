class_name LAMaterialFieldHeatQueue3D
extends LAMaterialFieldInjectQueue3D

## LAMaterialFieldHeatQueue3D: the pending-device-edit queue plus a THIRD book — TEMPERATURE.
##
## WHY IT IS A SUBCLASS AND NOT A `queue.add("temp", …)`. The base queue carries two ledgers, H₂O and MINERAL,
## and routes an edit into one of them by its channel name. `temp` belongs to neither: its unit is DEGREES, not
## mass, so folding it into `minted` would print a lightning bolt as water created from nothing and would make
## `h2o_inject_short` (demand minus moved) under-report every storm that ran on a dry footprint. A separate
## book is what lets a heat injection be applied through the SAME device-sparse path — the whole point of the
## queue — without corrupting the two conservation gauges the queue exists to publish.
##
## WHAT IT FIXES. `LAMaterialFieldInject3D.add_heat` used to write the CPU `_temp` mirror and call
## `mark_temp_dirty()`, which makes `LAMaterialSphereGPU3D.begin_frame` re-upload the WHOLE mirror over the
## live GPU temperature field. That mirror is one readback (up to two steps) old, so every heat injection threw
## away a step of solar absorption, radiative emission, conduction and buoyancy across all ~123,000 cells — to
## deliver a spike in a handful of them. This is exactly the rewind `add_vapor` was converted off, and the
## conversion simply never reached `add_heat`.
##
## THE ONE KNOWN LIMITATION, stated because it is a real inaccuracy and it is not mine to fix:
## `LAMaterialSphereGPU3D.add_field_sparse` ends with `after = maxf(0.0, before + delta)`. That floor is right
## for a MASS channel and wrong for a temperature in °C — a cell at -7 °C given +2 °C comes out at 0 °C rather
## than -5 °C, which creates heat, and a negative (cooling) edit can never take a cell below freezing at all.
## The proper fix is a signed sparse add (or a temperature channel in KELVIN, where a 0 floor is absolute zero
## and physically correct), and it lives in `MaterialSphereGPU3D.gd`, which another track owns. Measured on the
## baseline this matters little in practice — `clim_air_frozen` 0 of 32289 air cells, `clim_ground_frozen` 183
## of 4806, `clim_coldest_now` -7.4 °C — and every remaining injector dumps a LARGE positive spike (an impact,
## a bolt, a landing ejecta parcel), where the floor cannot bind. It is recorded here so it is not rediscovered.
## (Explicit types only, no ':=' inferred typing.)

# --- pending temperature edits (applied on device in flush, alongside the mass ops) --------------------------
var _t_cells: PackedInt32Array = PackedInt32Array()
var _t_deltas: PackedFloat32Array = PackedFloat32Array()

# --- cumulative THERMAL book (SIM_REPORT gauges) ------------------------------------------------------------
var heat_energy_j: float = 0.0     # ENERGY handed to add_heat_energy, in joules. This is the number that has
                                   # to come from somewhere: a bolt's electrostatic store, an impactor's
                                   # kinetic energy, a landing parcel's. It is booked here so a source that
                                   # stops being debited shows up as a rising figure with no matching debit.
var heat_unsourced_dc: float = 0.0 # DEGREES asked for by the raw `add_heat(pos, °C)` form, which names no
                                   # source at all. Two callers outside this substrate still use it
                                   # (CreatureDisease's fever, the editor's magma brush); keeping their demand
                                   # in its own figure is what stops "heat from nothing" hiding inside a total
                                   # that also contains properly sourced injections.
var heat_applied_dc: float = 0.0   # DEGREES the device actually applied (summed over cells), both forms.
var heat_cells: int = 0            # per-cell temperature edits that reached the device.


# --- pending CARBON edits + their own book -------------------------------------------------------------------
#
# The carbon-bearing channels (biomass, detritus, fuel, CO₂) need the same treatment as temperature and for
# the same reason: `transfer()` in the base class routes by channel name into either the H₂O or the MINERAL
# ledger, and a bite of grass is neither. Folding it into `h2o_inject_moved` would make `h2o_inject_short`
# — demand minus moved, the honest measure of a storm running on a dry footprint — stop meaning anything.
#
# `carbon_transfer` covers the case the base class has no name for: mass leaving the FIELD into an ACTOR
# (a herbivore's bite, a plant building tissue) with `dst_cells` of -1, and mass coming back the other way.
# Both sides are resolved on device against the live channel, so a debit can never exceed what is there.
var _c_ops: Array = []                 # {"src","src_cells","amounts","dst","dst_cells","ceiling"}
var _c_index: Dictionary = {}          # op signature -> slot in _c_ops, so same-signature edits COALESCE
var carbon_offered: float = 0.0        # carbon mass the CPU-side scan believed the source held
var carbon_moved: float = 0.0          # carbon mass the DEVICE actually moved (debit == credit by construction)
var carbon_returned: float = 0.0       # carbon mass handed BACK to the field from an actor's own stock
var carbon_cells: int = 0


## COALESCING IS NOT TIDINESS HERE, IT IS THE COST MODEL, and getting it wrong makes the frame rate collapse.
## Every op costs a FULL device buffer read and write-back (123k floats each way), and the dominant caller is
## per-plant uptake: several hundred plant nodes each asking their own cell for a fraction of a unit of
## biomass, every frame. One op per plant would be several hundred full-grid round-trips per frame. Folded
## into one op with several hundred cells it is a single round-trip, and `move_field_sparse` walks the cells
## in order against the values it is already updating, so repeated cells stay correct.
##
## THE `duplicate()` CALLS ARE LOAD-BEARING, for the reason the base class's `_merge` spells out at length:
## a caller may legitimately pass the same PackedInt32Array as both `src_cells` and `dst_cells` (the litter
## refill does — a cell's biomass becomes its own litter), the arrays are copy-on-write, and without the
## duplicates one `append_array` would grow a buffer the next `append_array` then grows again. Both sparse
## primitives early-return on a size mismatch, so the whole op would be dropped silently.
func _c_merge(key: String, src: String, src_cells: PackedInt32Array, amounts: PackedFloat32Array,
		dst: String, dst_cells: PackedInt32Array, ceiling: float) -> void:
	var slot: int = _c_index.get(key, -1)
	if slot < 0:
		_c_index[key] = _c_ops.size()
		_c_ops.append({"src": src, "src_cells": src_cells.duplicate(), "amounts": amounts.duplicate(),
			"dst": dst, "dst_cells": dst_cells.duplicate(), "ceiling": ceiling})
		return
	var op: Dictionary = _c_ops[slot]
	var sc: PackedInt32Array = (op["src_cells"] as PackedInt32Array).duplicate()
	var am: PackedFloat32Array = (op["amounts"] as PackedFloat32Array).duplicate()
	var dc: PackedInt32Array = (op["dst_cells"] as PackedInt32Array).duplicate()
	sc.append_array(src_cells)
	am.append_array(amounts)
	dc.append_array(dst_cells)
	op["src_cells"] = sc
	op["amounts"] = am
	op["dst_cells"] = dc


## Queue a CONSERVING carbon move. `dst_cells[i]` of -1 means the mass leaves the field entirely (into an
## actor that is now holding it and is expected to hand it back); `move_field_sparse` then debits the source
## and credits nobody, which is exactly the semantics that call wants.
func carbon_transfer(src: String, src_cells: PackedInt32Array, amounts: PackedFloat32Array,
		dst: String, dst_cells: PackedInt32Array, ceiling: float = INF) -> void:
	if src_cells.size() == 0 or src_cells.size() != amounts.size() or src_cells.size() != dst_cells.size():
		return
	for a in amounts:
		carbon_offered += a
	_c_merge("ct|%s|%s|%f" % [src, dst, ceiling], src, src_cells, amounts, dst, dst_cells, ceiling)


## Queue mass an ACTOR is handing back to the field out of its own stock — a plant's tissue rotting down to
## detritus when it is torn out. It is an `add` on the field's side, so it is booked as `carbon_returned` and
## is only honest as long as the actor's stock was itself drawn from the field. It is separate from
## `carbon_moved` precisely so the two can be compared: returns must never exceed draws.
func carbon_return(channel: String, cells: PackedInt32Array, deltas: PackedFloat32Array) -> void:
	if cells.size() == 0 or cells.size() != deltas.size():
		return
	_c_merge("cr|%s" % channel, channel, cells, deltas, "", PackedInt32Array(), INF)


## Queue a per-cell temperature edit. `cells[i]` gets `deltas[i]` °C, applied to the LIVE device buffer at the
## next flush — never written to the CPU mirror, which the readback owns.
func queue_temp(cells: PackedInt32Array, deltas: PackedFloat32Array) -> void:
	if cells.size() == 0 or cells.size() != deltas.size():
		return
	_t_cells.append_array(cells)
	_t_deltas.append_array(deltas)


## Book an ENERGY (joules) that was drawn from a named store and handed to the field as heat.
func note_energy(joules: float) -> void:
	heat_energy_j += joules


## Book DEGREES demanded by the raw, sourceless `add_heat` form.
func note_unsourced(degrees_times_cells: float) -> void:
	heat_unsourced_dc += degrees_times_cells


func is_empty() -> bool:
	return _t_cells.size() == 0 and _c_ops.is_empty() and super()


func flush(gpu) -> void:
	if gpu != null and _t_cells.size() > 0:
		heat_cells += _t_cells.size()
		heat_applied_dc += gpu.add_field_sparse("temp", _t_cells, _t_deltas)
		_t_cells = PackedInt32Array()
		_t_deltas = PackedFloat32Array()
	if gpu != null and not _c_ops.is_empty():
		for op in _c_ops:
			carbon_cells += (op["src_cells"] as PackedInt32Array).size()
			if String(op["dst"]).is_empty():
				carbon_returned += gpu.add_field_sparse(op["src"], op["src_cells"], op["amounts"])
			else:
				carbon_moved += gpu.move_field_sparse(op["src"], op["src_cells"], op["amounts"],
					op["dst"], op["dst_cells"], float(op["ceiling"]))
	_c_ops.clear()
	_c_index.clear()
	super(gpu)


func report() -> Dictionary:
	var out: Dictionary = super()
	out["heat_inject_j"] = snappedf(heat_energy_j, 0.01)
	out["heat_inject_unsourced_dc"] = snappedf(heat_unsourced_dc, 0.01)
	out["heat_inject_applied_dc"] = snappedf(heat_applied_dc, 0.01)
	out["heat_inject_cells"] = heat_cells
	out["carbon_inject_offered"] = snappedf(carbon_offered, 0.0001)
	out["carbon_inject_moved"] = snappedf(carbon_moved, 0.0001)
	out["carbon_inject_returned"] = snappedf(carbon_returned, 0.0001)
	out["carbon_inject_cells"] = carbon_cells
	return out
