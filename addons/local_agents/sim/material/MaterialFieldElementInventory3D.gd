class_name LAMaterialFieldElementInventory3D
extends RefCounted

const CellVolScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldCellVolume3D.gd")

## Carbon, oxygen, nitrogen, fertility and biomass, in channel units and in moles of element.

## Every channel this ledger sums, read as ONE read-only device sample (see `report()`).
const LEGS: PackedStringArray = ["co2", "o2", "detritus", "biomass", "fert", "fungus", "fuel", "n2"]

## The one declaration of what each channel is MADE OF, shared with the load-time reaction balance gate.
const BalanceScript: GDScript = preload("res://addons/local_agents/sim/material/reactions/ReactionBalance.gd")

## The one provenance predicate, shared with the seal and the mineral book.
const SealScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldSeal3D.gd")

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
	# n2 is probe-only: nothing reads it back, so `_f._n2` holds the seed forever and would read as a planet
	# whose nitrogen never moves. An absent leg reads as absent, and `mass_live` says so.
	var n2: PackedFloat32Array = legs.get("n2", PackedFloat32Array())
	# SUMMABLE — the array is the right length, whatever it came from. Says nothing about provenance.
	var has_n2: bool = n2.size() == cc
	var has_co2: bool = co2.size() == cc
	var has_o2: bool = o2.size() == cc
	var has_det: bool = det.size() == cc
	var has_bio: bool = bio.size() == cc
	var has_fert: bool = fert.size() == cc
	var has_fung: bool = fung.size() == cc
	var has_fuel: bool = fuel.size() == cc
	# MEASURED — the probe delivered it, or the readback refreshes it. A mirror fallback on a demand-gated
	# channel is a stale number, so it is summed above and reported dead here.
	var live_n2: bool = has_n2 and SealScript.channel_live(_f, "n2", legs, cc)
	var live_co2: bool = has_co2 and SealScript.channel_live(_f, "co2", legs, cc)
	var live_o2: bool = has_o2 and SealScript.channel_live(_f, "o2", legs, cc)
	var live_det: bool = has_det and SealScript.channel_live(_f, "detritus", legs, cc)
	var live_bio: bool = has_bio and SealScript.channel_live(_f, "biomass", legs, cc)
	var live_fert: bool = has_fert and SealScript.channel_live(_f, "fert", legs, cc)
	var live_fung: bool = has_fung and SealScript.channel_live(_f, "fungus", legs, cc)
	var live_fuel: bool = has_fuel and SealScript.channel_live(_f, "fuel", legs, cc)

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
	var n2_open: float = 0.0
	var n2_all: float = 0.0
	var open_cells: int = 0
	var vol: PackedFloat32Array = CellVolScript.of(_f)
	if vol.size() != cc:
		return out
	for c in cc:
		var is_open: bool = solid[c] == 0
		var w: float = vol[c]
		if has_co2:
			var v: float = co2[c] * w
			co2_all += v
			if is_open:
				co2_open += v
		if has_o2:
			var v2: float = o2[c] * w
			o2_all += v2
			if is_open:
				o2_open += v2
		if has_det:
			var v3: float = det[c] * w
			det_all += v3
			if is_open:
				det_open += v3
		if has_bio:
			var v4: float = bio[c] * w
			bio_all += v4
			if is_open:
				bio_open += v4
		if has_fert:
			var v5: float = fert[c] * w
			fert_all += v5
			if is_open:
				fert_open += v5
		if has_fung:
			var v6: float = fung[c] * w
			fung_all += v6
			if is_open:
				fung_open += v6
		if has_fuel:
			var v7: float = fuel[c] * w
			fuel_all += v7
			if is_open:
				fuel_open += v7
		if has_n2:
			var v8: float = n2[c] * w
			n2_all += v8
			if is_open:
				n2_open += v8
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
	# NOT SNAPPED. One unit of FERT is a cell packed solid with elemental N at rock density, so a real soil
	# nitrogen stock is ~1e-7 units per cell and a 0.01 quantum could only ever print 0.00 — a gauge whose
	# resolution is five orders of magnitude coarser than the quantity it measures cannot answer the question
	# it is asked. Same for the drift and the baseline below.
	out["fert_total"] = fert_open
	out["fert_all"] = fert_all
	out["n2_total"] = snappedf(n2_open, 0.01)
	out["n2_all"] = snappedf(n2_all, 0.01)
	out["biomass_open_total"] = snappedf(bio_open, 0.01)
	out["fungus_total"] = snappedf(fung_open, 0.01)
	out["fungus_all"] = snappedf(fung_all, 0.01)
	out["fuel_open_total"] = snappedf(fuel_open, 0.01)
	out["fuel_all"] = snappedf(fuel_all, 0.01)
	out["mass_open_cells"] = open_cells
	# PROVENANCE. A leg whose channel never arrived from the GPU reads as a flat zero, which is
	# indistinguishable from a substance that genuinely is not there. This says which is which.
	out["mass_live"] = {
		"co2": live_co2, "o2": live_o2, "detritus": live_det, "biomass": live_bio,
		"fert": live_fert, "fungus": live_fung, "fuel": live_fuel, "n2": live_n2,
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
			out["fert_drift"] = fert_open - _prev_fert
			out["fert_drift_per_step"] = (fert_open - _prev_fert) * inv
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
		"fert": fert_open, "fungus": fung_open, "fuel": fuel_open, "n2": n2_open,
	}
	var all_by_channel: Dictionary = {
		"co2": co2_all, "o2": o2_all, "detritus": det_all, "biomass": bio_all,
		"fert": fert_all, "fungus": fung_all, "fuel": fuel_all, "n2": n2_all,
	}
	var elements: Dictionary = elements_of(open_by_channel)
	for el in elements:
		out["element_" + String(el)] = snappedf(float(elements[el]), 0.01)
	var elements_all: Dictionary = elements_of(all_by_channel)
	for el_a in elements_all:
		out["element_" + String(el_a) + "_all"] = snappedf(float(elements_all[el_a]), 0.01)
	# STRAIGHT OFF THE ELEMENT SUMS. This used to be `fert + (bio+det+fung+fuel)/LITTER_C_TO_N`, which divided
	# CHANNEL UNITS by a carbon-to-nitrogen MASS ratio and so was neither moles nor kilograms: it weighted
	# organic N against fertility 13.5x too heavily, while the composition table beside it already carries
	# cellulose's N per unit. Two gauges for one quantity, and the wrong one was the gated one.
	var nitrogen: float = float(elements.get("N", 0.0))
	var nitrogen_all: float = float(elements_all.get("N", 0.0))
	out["oxidant_total"] = snappedf(oxidant, 0.01)
	out["oxidant_all"] = snappedf(oxidant_all, 0.01)
	out["carbon_closed_total"] = snappedf(carbon_closed, 0.01)
	out["carbon_closed_all"] = snappedf(carbon_closed_all, 0.01)
	out["carbon_closed_buried"] = snappedf(carbon_closed_all - carbon_closed, 0.01)
	out["nitrogen_total"] = snappedf(nitrogen, 0.01)
	out["nitrogen_all"] = snappedf(nitrogen_all, 0.01)
	out["nitrogen_buried"] = snappedf(nitrogen_all - nitrogen, 0.01)

	var run_steps: int = 0
	if live_co2 and live_bio and live_det:
		if _first_carbon_step < 0 and _at_seal(step_index):
			_first_carbon = carbon
			_note_seed("carbon", carbon)
			_first_carbon_step = step_index
		run_steps = step_index - _first_carbon_step
		out["carbon_first"] = snappedf(_first_carbon, 0.01)
		if run_steps > 0:
			out["carbon_run_drift_per_step"] = snappedf((carbon - _first_carbon) / float(run_steps), 0.0001)
	if live_o2:
		if _first_o2_step < 0 and _at_seal(step_index):
			_first_o2 = o2_open
			_note_seed("o2", o2_open)
			_first_o2_step = step_index
		out["o2_first"] = snappedf(_first_o2, 0.01)
		if step_index > _first_o2_step:
			out["o2_run_drift_per_step"] = snappedf(
				(o2_open - _first_o2) / float(step_index - _first_o2_step), 0.0001)
	if live_fert:
		if _first_fert_step < 0 and _at_seal(step_index):
			_first_fert = fert_open
			_first_fert_step = step_index
		out["fert_first"] = _first_fert
		if step_index > _first_fert_step:
			out["fert_run_drift_per_step"] = (fert_open - _first_fert) / float(step_index - _first_fert_step)
	if live_bio:
		if _first_biomass_step < 0 and _at_seal(step_index):
			_first_biomass = bio_open
			_first_biomass_step = step_index
		out["biomass_first"] = snappedf(_first_biomass, 0.01)
		if step_index > _first_biomass_step:
			out["biomass_run_drift_per_step"] = snappedf(
				(bio_open - _first_biomass) / float(step_index - _first_biomass_step), 0.0001)
	if live_o2 and live_co2:
		if _first_oxidant_step < 0 and _at_seal(step_index):
			_first_oxidant = oxidant_all
			_first_oxidant_step = step_index
		# `oxidant_first` latches the MASK-FREE total, because that is what the gate compares against.
		out["oxidant_first"] = snappedf(_first_oxidant, 0.01)
		if step_index > _first_oxidant_step:
			out["oxidant_run_drift_per_step"] = snappedf(
				(oxidant - _first_oxidant) / float(step_index - _first_oxidant_step), 0.0001)
	if live_co2 and live_bio and live_det and live_fung and live_fuel:
		if _first_closed_step < 0 and _at_seal(step_index):
			_first_closed = carbon_closed_all
			_first_closed_step = step_index
		out["carbon_closed_first"] = snappedf(_first_closed, 0.01)
		if step_index > _first_closed_step:
			out["carbon_closed_run_drift_per_step"] = snappedf(
				(carbon_closed_all - _first_closed) / float(step_index - _first_closed_step), 0.0001)
	if live_fert and live_bio and live_det and live_fung and live_fuel and live_n2:
		if _first_nitrogen_step < 0 and _at_seal(step_index):
			_first_nitrogen = nitrogen_all
			_first_nitrogen_step = step_index
		out["nitrogen_first"] = snappedf(_first_nitrogen, 0.01)
		if step_index > _first_nitrogen_step:
			out["nitrogen_run_drift_per_step"] = snappedf(
				(nitrogen_all - _first_nitrogen) / float(step_index - _first_nitrogen_step), 0.0001)
	out["mass_run_steps"] = run_steps
	out["mass_scan_ms"] = snappedf(float(Time.get_ticks_usec() - t0) / 1000.0, 0.01)
	return out


## Channel amount (units x cell volume) -> MOLES of each element it contains, through the same
## LAReactionBalance declaration the load-time balance gate checks every record against. The one conversion:
## LAMaterialFieldElementProbe3D attributes per-pass element movement with this exact function.
static func elements_of(by_channel: Dictionary) -> Dictionary:
	var slots: Dictionary = BalanceScript.inventory_channels()
	var elements: Dictionary = {}
	for ch in by_channel:
		var parts: Dictionary = BalanceScript.channel_elements(ch)
		var moles: float = float(by_channel[ch])
		for el in parts:
			elements[el] = float(elements.get(el, 0.0)) + moles * float(parts[el])
	return elements


## Every stored channel whose composition carries `element`. The probe reads only these, so asking where the
## carbon went costs six channel reads rather than nineteen.
static func channels_with(element: String) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for ch in BalanceScript.inventory_channels():
		if BalanceScript.channel_elements(ch).has(element):
			out.append(String(ch))
	return out


## Every element any stored channel carries.
static func all_elements() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for ch in BalanceScript.inventory_channels():
		for el in BalanceScript.channel_elements(ch):
			if not out.has(String(el)):
				out.append(String(el))
	return out


func _blank() -> Dictionary:
	return {
		"carbon_total": 0.0, "carbon_all": 0.0, "carbon_buried": 0.0,
		"carbon_co2": 0.0, "carbon_biomass": 0.0, "carbon_detritus": 0.0,
		"carbon_drift": 0.0, "carbon_drift_per_step": 0.0,
		"o2_total": 0.0, "o2_all": 0.0, "o2_drift": 0.0, "o2_drift_per_step": 0.0,
		"fert_total": 0.0, "fert_all": 0.0, "fert_drift": 0.0, "fert_drift_per_step": 0.0,
		"biomass_open_total": 0.0, "biomass_drift": 0.0, "biomass_drift_per_step": 0.0,
		"fungus_total": 0.0, "fungus_all": 0.0, "fuel_open_total": 0.0, "fuel_all": 0.0,
		"n2_total": 0.0, "n2_all": 0.0,
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


## True only on the step LAMaterialFieldSeal3D latched the books. The seal drives one sample there; a sample
## on any other step cannot take a baseline, so a late one is impossible rather than merely unlikely.
func _at_seal(step_index: int) -> bool:
	return _f != null and _f._seal != null and step_index == _f._seal.baseline_step()


func _note_seed(key: String, value: float) -> void:
	if _f != null and _f._seal != null:
		_f._seal.note_seed({key: value})
