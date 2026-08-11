class_name LAMaterialFieldElementInventory3D
extends RefCounted

##   carbon_total = co2 + biomass + detritus.

## Every channel this ledger sums, read as ONE read-only device sample (see `report()`).
const LEGS: PackedStringArray = ["co2", "o2", "detritus", "biomass", "fert", "fungus", "fuel"]

## The one declaration of what each channel is MADE OF, shared with the load-time reaction balance gate.
const BalanceScript: GDScript = preload("res://addons/local_agents/sim/material/reactions/ReactionBalance.gd")

var _f = null                                # back-reference to the owning LAMaterialField3D

# Previous sample, for the drift. NAN until the first sample so the first reading reports no drift rather
# than a spurious one — the same convention LAMaterialFieldLedger3D uses.
var _prev_carbon: float = NAN
var _prev_o2: float = NAN
var _prev_fert: float = NAN
var _prev_biomass: float = NAN
var _prev_step: int = -1

var _first_carbon: float = NAN
var _first_o2: float = NAN
var _first_fert: float = NAN
var _first_biomass: float = NAN
var _first_oxidant: float = NAN
var _first_closed: float = NAN
var _first_carbon_step: int = -1
var _first_o2_step: int = -1
var _first_fert_step: int = -1
var _first_biomass_step: int = -1
var _first_oxidant_step: int = -1
var _first_closed_step: int = -1
var _first_nitrogen: float = NAN
var _first_nitrogen_step: int = -1


func setup(field) -> void:
	_f = field


## The four ledgers, sampled together in one pass. `step_index` is the field's own step counter — drift is
## reported PER FIELD STEP, never per frame, because these are draining/filling reservoirs whose value tracks
## steps taken and a frame-based rate would track framerate instead of physics.
func report(step_index: int) -> Dictionary:
	var out: Dictionary = _blank()
	if _f == null or _f._cell_count <= 0:
		return out
	var t0: int = Time.get_ticks_usec()
	var cc: int = _f._cell_count
	var solid: PackedByteArray = _f._solid
	if solid.size() != cc:
		return out
	var legs: Dictionary = {}
	if _f._gpu != null and _f._gpu.has_method("take_probe"):
		legs = _f._gpu.take_probe()
		_f._gpu.request_probe(LEGS)
	var co2: PackedFloat32Array = legs.get("co2", _f._co2)
	var o2: PackedFloat32Array = legs.get("o2", _f._o2)
	var det: PackedFloat32Array = legs.get("detritus", _f._detritus)
	var bio: PackedFloat32Array = legs.get("biomass", _f._biomass)
	var fert: PackedFloat32Array = legs.get("fert", _f._fert)
	var fung: PackedFloat32Array = legs.get("fungus", _f._fungus)
	var fuel: PackedFloat32Array = legs.get("fuel", _f._fuel)
	var has_co2: bool = co2.size() == cc
	var has_o2: bool = o2.size() == cc
	var has_det: bool = det.size() == cc
	var has_bio: bool = bio.size() == cc
	var has_fert: bool = fert.size() == cc
	var has_fung: bool = fung.size() == cc
	var has_fuel: bool = fuel.size() == cc

	var co2_open: float = 0.0
	var co2_all: float = 0.0
	var o2_open: float = 0.0
	var o2_all: float = 0.0
	var det_open: float = 0.0
	var det_all: float = 0.0
	var bio_open: float = 0.0
	var bio_all: float = 0.0
	var fert_open: float = 0.0
	var fert_all: float = 0.0
	var fung_open: float = 0.0
	var fung_all: float = 0.0
	var fuel_open: float = 0.0
	var fuel_all: float = 0.0
	var open_cells: int = 0
	# VOLUME-WEIGHTED, IN CUBIC METRES, and the unit is not optional here. A channel value says how full a
	# cell is; the amount of substance is that times the cell's volume, and this grid's cells differ by up
	# to 8.8x — so summing raw made these totals a function of where in the shell a substance happened to be
	# sitting, and a gas simply rising changed `carbon_total` with no carbon created or destroyed.
	#
	# CUBIC METRES because `_elements_of` multiplies these by LAReactionBalance.mol_per_unit(), which is
	# density / molar_mass, i.e. MOL PER CUBIC METRE. A dimensionless sum times mol/m^3 is not moles, so
	# `element_C_mol` — the figure PHYSICS_RUBRIC criterion 1 is scored on — was never in moles.
	var grid = _f._sphere
	var have_grid: bool = grid != null and grid.cell_count == cc
	for c in cc:
		var is_open: bool = solid[c] == 0
		var vol: float = LAFieldTotals.cell_volume_m3(grid, c) if have_grid else 1.0
		if has_co2:
			var v: float = co2[c] * vol
			co2_all += v
			if is_open:
				co2_open += v
		if has_o2:
			var v2: float = o2[c] * vol
			o2_all += v2
			if is_open:
				o2_open += v2
		if has_det:
			var v3: float = det[c] * vol
			det_all += v3
			if is_open:
				det_open += v3
		if has_bio:
			var v4: float = bio[c] * vol
			bio_all += v4
			if is_open:
				bio_open += v4
		if has_fert:
			var v5: float = fert[c] * vol
			fert_all += v5
			if is_open:
				fert_open += v5
		if has_fung:
			var v6: float = fung[c] * vol
			fung_all += v6
			if is_open:
				fung_open += v6
		if has_fuel:
			var v7: float = fuel[c] * vol
			fuel_all += v7
			if is_open:
				fuel_open += v7
		if is_open:
			open_cells += 1

	var carbon: float = co2_open + bio_open + det_open
	var carbon_all: float = co2_all + bio_all + det_all
	out["carbon_total"] = snappedf(carbon, 0.01)
	out["carbon_all"] = snappedf(carbon_all, 0.01)
	out["carbon_buried"] = snappedf(carbon_all - carbon, 0.01)
	out["carbon_co2"] = snappedf(co2_open, 0.01)
	out["carbon_biomass"] = snappedf(bio_open, 0.01)
	out["carbon_detritus"] = snappedf(det_open, 0.01)
	out["o2_total"] = snappedf(o2_open, 0.01)
	out["o2_all"] = snappedf(o2_all, 0.01)
	out["fert_total"] = snappedf(fert_open, 0.01)
	out["fert_all"] = snappedf(fert_all, 0.01)
	out["biomass_open_total"] = snappedf(bio_open, 0.01)
	# MEMO LINES — carbon-bearing but outside the reaction table's closed triangle (see the header). Both carry
	# mask-free counterpart, which is what made `nitrogen_total` unable to tell burial from destruction.
	out["fungus_total"] = snappedf(fung_open, 0.01)
	out["fungus_all"] = snappedf(fung_all, 0.01)
	out["fuel_open_total"] = snappedf(fuel_open, 0.01)
	out["fuel_all"] = snappedf(fuel_all, 0.01)
	out["mass_open_cells"] = open_cells
	# PROVENANCE. A leg whose channel never arrived from the GPU reads as a flat zero, which is
	# indistinguishable from a substance that genuinely is not there. This says which is which.
	out["mass_live"] = {
		"co2": has_co2, "o2": has_o2, "detritus": has_det, "biomass": has_bio,
		"fert": has_fert, "fungus": has_fung, "fuel": has_fuel,
	}

	# DRIFT — the whole point. Per FIELD STEP, against the previous sample.
	var steps: int = step_index - _prev_step
	if steps > 0 and _prev_step >= 0:
		var inv: float = 1.0 / float(steps)
		if not is_nan(_prev_carbon):
			out["carbon_drift"] = snappedf(carbon - _prev_carbon, 0.01)
			out["carbon_drift_per_step"] = snappedf((carbon - _prev_carbon) * inv, 0.0001)
		if not is_nan(_prev_o2):
			out["o2_drift"] = snappedf(o2_open - _prev_o2, 0.01)
			out["o2_drift_per_step"] = snappedf((o2_open - _prev_o2) * inv, 0.0001)
		if not is_nan(_prev_fert):
			out["fert_drift"] = snappedf(fert_open - _prev_fert, 0.01)
			out["fert_drift_per_step"] = snappedf((fert_open - _prev_fert) * inv, 0.0001)
		if not is_nan(_prev_biomass):
			out["biomass_drift"] = snappedf(bio_open - _prev_biomass, 0.01)
			out["biomass_drift_per_step"] = snappedf((bio_open - _prev_biomass) * inv, 0.0001)
		out["mass_drift_steps"] = steps
	if steps > 0 or _prev_step < 0:
		_prev_carbon = carbon
		_prev_o2 = o2_open
		_prev_fert = fert_open
		_prev_biomass = bio_open
		_prev_step = step_index
	# THE TWO GAUGES THAT ARE ACTUALLY CONSERVED (see the header). `oxidant_total` is the O₂-equivalent sum
	# the reaction table provably holds; `carbon_closed_total` is carbon over EVERY pool that carries it, not
	# only the three the reaction table moves between.
	var oxidant: float = o2_open + co2_open
	var oxidant_all: float = o2_all + co2_all
	var carbon_closed: float = carbon + fung_open + fuel_open
	var carbon_closed_all: float = carbon_all + fung_all + fuel_all
	var open_by_channel: Dictionary = {
		"co2": co2_open, "o2": o2_open, "detritus": det_open, "biomass": bio_open,
		"fert": fert_open, "fungus": fung_open, "fuel": fuel_open,
	}
	var all_by_channel: Dictionary = {
		"co2": co2_all, "o2": o2_all, "detritus": det_all, "biomass": bio_all,
		"fert": fert_all, "fungus": fung_all, "fuel": fuel_all,
	}
	var elements: Dictionary = _elements_of(open_by_channel)
	for el in elements:
		out["element_" + String(el)] = snappedf(float(elements[el]), 0.01)
	var elements_all: Dictionary = _elements_of(all_by_channel)
	for el_a in elements_all:
		out["element_" + String(el_a) + "_all"] = snappedf(float(elements_all[el_a]), 0.01)
	var nitrogen: float = fert_open + (bio_open + det_open + fung_open + fuel_open) / LAPhysical.LITTER_C_TO_N
	var nitrogen_all: float = fert_all + (bio_all + det_all + fung_all + fuel_all) / LAPhysical.LITTER_C_TO_N
	out["oxidant_total"] = snappedf(oxidant, 0.01)
	out["oxidant_all"] = snappedf(oxidant_all, 0.01)
	out["carbon_closed_total"] = snappedf(carbon_closed, 0.01)
	out["carbon_closed_all"] = snappedf(carbon_closed_all, 0.01)
	out["carbon_closed_buried"] = snappedf(carbon_closed_all - carbon_closed, 0.01)
	out["nitrogen_total"] = snappedf(nitrogen, 0.01)
	out["nitrogen_all"] = snappedf(nitrogen_all, 0.01)
	out["nitrogen_buried"] = snappedf(nitrogen_all - nitrogen, 0.01)

	var run_steps: int = 0
	if has_co2 and has_bio and has_det:
		if _first_carbon_step < 0 and _sealed():
			_first_carbon = carbon
			_note_seed("carbon", carbon)
			_first_carbon_step = step_index
		run_steps = step_index - _first_carbon_step
		out["carbon_first"] = snappedf(_first_carbon, 0.01)
		if run_steps > 0:
			out["carbon_run_drift_per_step"] = snappedf((carbon - _first_carbon) / float(run_steps), 0.0001)
	if has_o2:
		if _first_o2_step < 0 and _sealed():
			_first_o2 = o2_open
			_note_seed("o2", o2_open)
			_first_o2_step = step_index
		out["o2_first"] = snappedf(_first_o2, 0.01)
		if step_index > _first_o2_step:
			out["o2_run_drift_per_step"] = snappedf(
				(o2_open - _first_o2) / float(step_index - _first_o2_step), 0.0001)
	if has_fert:
		if _first_fert_step < 0 and _sealed():
			_first_fert = fert_open
			_first_fert_step = step_index
		out["fert_first"] = snappedf(_first_fert, 0.01)
		if step_index > _first_fert_step:
			out["fert_run_drift_per_step"] = snappedf(
				(fert_open - _first_fert) / float(step_index - _first_fert_step), 0.0001)
	if has_bio:
		if _first_biomass_step < 0 and _sealed():
			_first_biomass = bio_open
			_first_biomass_step = step_index
		out["biomass_first"] = snappedf(_first_biomass, 0.01)
		if step_index > _first_biomass_step:
			out["biomass_run_drift_per_step"] = snappedf(
				(bio_open - _first_biomass) / float(step_index - _first_biomass_step), 0.0001)
	if has_o2 and has_co2:
		if _first_oxidant_step < 0 and _sealed():
			_first_oxidant = oxidant_all
			_first_oxidant_step = step_index
		# `oxidant_first` latches the MASK-FREE total, because that is what the gate compares against.
		out["oxidant_first"] = snappedf(_first_oxidant, 0.01)
		if step_index > _first_oxidant_step:
			out["oxidant_run_drift_per_step"] = snappedf(
				(oxidant - _first_oxidant) / float(step_index - _first_oxidant_step), 0.0001)
	# leak.)* `carbon_run_drift_per_step` above deliberately stays on the OPEN total: that one is the narrow
	# three-slot triangle, whose job is to LOCALISE a leak to one side of the reaction table, and its mask-free
	# reading is already published as `carbon_all`.
	if has_co2 and has_bio and has_det and has_fung and has_fuel:
		if _first_closed_step < 0 and _sealed():
			_first_closed = carbon_closed_all
			_first_closed_step = step_index
		out["carbon_closed_first"] = snappedf(_first_closed, 0.01)
		if step_index > _first_closed_step:
			out["carbon_closed_run_drift_per_step"] = snappedf(
				(carbon_closed_all - _first_closed) / float(step_index - _first_closed_step), 0.0001)
	if has_fert and has_bio and has_det and has_fung and has_fuel:
		if _first_nitrogen_step < 0 and _sealed():
			_first_nitrogen = nitrogen_all
			_first_nitrogen_step = step_index
		out["nitrogen_first"] = snappedf(_first_nitrogen, 0.01)
		if step_index > _first_nitrogen_step:
			out["nitrogen_run_drift_per_step"] = snappedf(
				(nitrogen_all - _first_nitrogen) / float(step_index - _first_nitrogen_step), 0.0001)
	out["mass_run_steps"] = run_steps
	out["mass_scan_ms"] = snappedf(float(Time.get_ticks_usec() - t0) / 1000.0, 0.01)
	return out


## Multiply each channel's stored amount by the ELEMENTS one unit of it contains, read from the same
## LAReactionBalance declaration the load-time balance gate checks every record against. Called once per mask.
func _elements_of(by_channel: Dictionary) -> Dictionary:
	# in a cell of ambient air (8.535 mol/m³) against one unit of `water`'s cell FULL of liquid water (55343).
	var mpu: Dictionary = BalanceScript.mol_per_unit()
	var slots: Dictionary = BalanceScript.INVENTORY_CHANNELS
	var elements: Dictionary = {}
	for ch in by_channel:
		var parts: Dictionary = BalanceScript.channel_elements(ch)
		var moles: float = float(by_channel[ch]) * float(mpu.get(int(slots.get(ch, -1)), 1.0))
		for el in parts:
			elements[el] = float(elements.get(el, 0.0)) + moles * float(parts[el])
	return elements


func _blank() -> Dictionary:
	return {
		"carbon_total": 0.0, "carbon_all": 0.0, "carbon_buried": 0.0,
		"carbon_co2": 0.0, "carbon_biomass": 0.0, "carbon_detritus": 0.0,
		"carbon_drift": 0.0, "carbon_drift_per_step": 0.0,
		"o2_total": 0.0, "o2_all": 0.0, "o2_drift": 0.0, "o2_drift_per_step": 0.0,
		"fert_total": 0.0, "fert_all": 0.0, "fert_drift": 0.0, "fert_drift_per_step": 0.0,
		"biomass_open_total": 0.0, "biomass_drift": 0.0, "biomass_drift_per_step": 0.0,
		"fungus_total": 0.0, "fungus_all": 0.0, "fuel_open_total": 0.0, "fuel_all": 0.0,
		"mass_open_cells": 0, "mass_drift_steps": 0, "mass_run_steps": 0, "mass_scan_ms": 0.0,
		"carbon_first": 0.0, "o2_first": 0.0, "fert_first": 0.0, "biomass_first": 0.0,
		"carbon_run_drift_per_step": 0.0, "o2_run_drift_per_step": 0.0,
		"fert_run_drift_per_step": 0.0, "biomass_run_drift_per_step": 0.0,
		"oxidant_total": 0.0, "oxidant_first": 0.0, "oxidant_run_drift_per_step": 0.0,
		"carbon_closed_total": 0.0, "carbon_closed_all": 0.0, "carbon_closed_buried": 0.0,
		"carbon_closed_first": 0.0, "carbon_closed_run_drift_per_step": 0.0,
		"nitrogen_total": 0.0, "nitrogen_all": 0.0, "nitrogen_buried": 0.0,
		"nitrogen_first": 0.0, "nitrogen_run_drift_per_step": 0.0,
		"mass_live": {},
	}


## True once LAMaterialFieldSeal3D has closed the books. Before it, this module publishes totals but latches
## no baseline and reports no run-drift — because until the world is sealed the only thing a drift gauge can
## measure is the planet being assembled.
func _sealed() -> bool:
	return _f != null and _f._seal != null and _f._seal.sealed()


func _note_seed(key: String, value: float) -> void:
	if _f != null and _f._seal != null:
		_f._seal.note_seed({key: value})
