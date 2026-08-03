class_name LAMaterialFieldMassBudget3D
extends RefCounted

## LAMaterialFieldMassBudget3D — CONSERVATION LEDGERS FOR CARBON, OXYGEN, FERTILITY AND BIOMASS, built to the
## shape LAMaterialFieldLedger3D already proved on H₂O: a total per substance, and a DRIFT PER FIELD STEP
## against the previous sample. The drift is the instrument. A total printed as an absolute cannot show a slow
## leak — that is exactly how the water leak hid — and it cannot show minting at all.
##
## WHY THESE FOUR AND WHY NOW. The correlation is hard to miss once someone looks: every substance in this
## simulation that HAS a ledger conserves, and every substance without one mints. H₂O has `h2o_total`,
## `h2o_drift_per_step` and per-pass probes, and its transfers are real transfers. Minerals have
## `mineral_total`. Carbon, oxygen and fertility had NOTHING — a grep for carbon_total / co2_total / o2_total
## under sim/material/ returned zero — and all three mint:
##   * CARBON has no source pool at all. `_co2` is allocated and NOT filled (MaterialField3D.gd:443-445 —
##     the line above it fills `_o2` with O2_AMBIENT, so the omission is visible in the diff), and the
##     planet's entire carbon inventory then arrives through ONE record, R12's RELAX_TARGET toward
##     CO2_AMBIENT_TRACE. RELAX_TARGET carries no reactant list and reactions_sphere3d.glsl skips the
##     reactant-cap block for it, so R12 is a tap with no tank behind it.
##   * OXYGEN gains on every turn of the carbon cycle. Photosynthesis (R19) yields PHOTO_O2_YIELD 1.0 per unit
##     of carbon fixed; respiration (R20) spends RESP_O2_COST 0.5 to undo it, and decomposition (R15) spends
##     O2_PER_DECOMPOSE 0.8 against CO2_PER_DECOMPOSE 1.0. The two directions are chemical inverses and their
##     coefficients are not equal, so each cycle leaves free oxygen behind.
##   * FERTILITY is minted at roughly 75:1 per unit of extent: FERT_PER_DECOMPOSE 1.5 produced against
##     FERT_UPTAKE_COST 0.02 consumed, with no source pool on either side.
## This module does NOT fix any of that. It is the instrument that makes the drift a number instead of an
## argument, and a drift that comes back POSITIVE is the correct result to report, not a bug in the meter.
##
## THE INCLUSION RULE, and it is the same lesson the water ledger learned the hard way: every leg uses ONE
## mask, or the ledger's own disagreement gets read as physics. Here every leg is summed over OPEN cells
## (`solid[c] == 0`), because that is where all four substances live and where every kernel that moves them
## gates. Static cells are INCLUDED for the same reason the water ledger includes them: static marks what is
## SIMULATED, not what EXISTS.
##
## AND EVERY LEG IS ALSO SUMMED MASK-FREE (`*_all`). The difference between the two is a real quantity, not a
## rounding check: a cell that turns solid with biomass or detritus in it has BURIED that mass, not destroyed
## it, and a ledger with one mask cannot tell burial from a kernel dropping mass. The H₂O budget found exactly
## that case, which is why the pattern is copied rather than reinvented.
##
## CARBON'S CONVENTION, stated because a conserved quantity is only as meaningful as its boundary:
##   carbon_total = co2 + biomass + detritus.
## Those are the three slots the reaction table actually moves carbon between, and between them the
## stoichiometry IS closed: R19 fixes 1 CO₂ into 1 biomass, R20 turns 1 biomass into 0.6 CO₂ + 0.4 detritus
## (0.6 + 0.4 = 1), R15 rots 1 detritus into 1 CO₂. So any drift in this sum is R12 minting or a kernel
## outside the reaction table, and nothing else. FUEL and FUNGUS are carbon-bearing in the real world but are
## moved by their own kernels (fire_sphere3d, fungus_sphere3d) with no stoichiometric link to this triangle,
## so folding them in would hide R12's signature inside two unrelated budgets. They are reported BESIDE the
## total as memo lines instead, so a reader can add them and see what happens.
##
## OXYGEN'S CONVENTION: FREE molecular O₂ only — the `o2` channel — and NOT the oxygen bound in CO₂. The
## reaction table treats CO₂ as an indivisible unit and never converts between bound and free oxygen
## atom-for-atom, so counting bound O would import a stoichiometry the substrate does not implement and
## produce a "conserved" total that no kernel is trying to conserve.
##
## READBACK. `detritus` and `fungus` were NEVER READ BACK from the GPU before 2026-08-03 — they appear in no
## hot, situational or slow readback set — so their CPU mirrors held the all-zero allocation for the life of
## every process, and `detritus_peak` / `fungus_cells` / `fungus_peak` in SIM_REPORT have been reporting that
## seed rather than the simulation. They are demand-gated now and this module requests them; `mass_live`
## reports which channels arrived, so a total built on a stale mirror is never mistaken for a measurement.
##
## Costs ONE O(cells) pass accumulating every leg at once, on the report's snapshot cadence.
## (Explicit types only, no ':=' inferred typing.)

## Every channel this ledger sums, read as ONE read-only device sample (see `report()`).
const LEGS: PackedStringArray = ["co2", "o2", "detritus", "biomass", "fert", "fungus", "fuel"]

var _f = null                                # back-reference to the owning LAMaterialField3D

# Previous sample, for the drift. NAN until the first sample so the first reading reports no drift rather
# than a spurious one — the same convention LAMaterialFieldLedger3D uses.
var _prev_carbon: float = NAN
var _prev_o2: float = NAN
var _prev_fert: float = NAN
var _prev_biomass: float = NAN
var _prev_step: int = -1

# FIRST sample, and the run-long drift measured against it. The per-sample drift above is one short window —
# 15 field steps at the report's cadence — and a single window is a sample, not a trend: it catches whatever
# eruption or wildfire happened to be burning. The run-long figure divides the WHOLE change by the WHOLE
# number of steps, so it is the number to quote for "does this substance mint", and the two disagreeing is
# itself informative (a substance that is bounded but noisy shows a large per-sample drift and a run-long one
# near zero).
var _first_carbon: float = NAN
var _first_o2: float = NAN
var _first_fert: float = NAN
var _first_biomass: float = NAN
var _first_step: int = -1


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
	# THE LEGS, SAMPLED READ-ONLY. *(Changed 2026-08-03. This used to call `request_channel` on co2, detritus,
	# fungus and fuel "so a build that never takes a snapshot pays nothing". That is not free either way:
	# residency decides what the CPU MIRRORS hold, and the simulation's own write paths read those mirrors —
	# `LAMaterialSurfaceSeed3D.post_readback()` refills fuel from `_f._fuel` and pushes the WHOLE mirror back
	# with `set_field`, so how stale it is decides how much GPU-evolved fuel that upload rewinds. A ledger must
	# not be able to change a fire. See the `request_channel` docstring in LAMaterialSphereGPU3D for the full
	# list of mirror-reading write paths.)* Collect the probe the previous sample armed and arm the next; the
	# mirrors stand in until the first one lands, and `mass_live` says which legs arrived.
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
	var fuel_open: float = 0.0
	var open_cells: int = 0
	for c in cc:
		var is_open: bool = solid[c] == 0
		if has_co2:
			var v: float = co2[c]
			co2_all += v
			if is_open:
				co2_open += v
		if has_o2:
			var v2: float = o2[c]
			o2_all += v2
			if is_open:
				o2_open += v2
		if has_det:
			var v3: float = det[c]
			det_all += v3
			if is_open:
				det_open += v3
		if has_bio:
			var v4: float = bio[c]
			bio_all += v4
			if is_open:
				bio_open += v4
		if has_fert:
			var v5: float = fert[c]
			fert_all += v5
			if is_open:
				fert_open += v5
		if is_open:
			open_cells += 1
			if has_fung:
				fung_open += fung[c]
			if has_fuel:
				fuel_open += fuel[c]

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
	# MEMO LINES — carbon-bearing but outside the reaction table's closed triangle (see the header).
	out["fungus_total"] = snappedf(fung_open, 0.01)
	out["fuel_open_total"] = snappedf(fuel_open, 0.01)
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
	# RUN-LONG DRIFT — the headline conservation figure. First sample is the baseline; everything after is
	# measured against it over the field steps actually elapsed.
	if _first_step < 0:
		_first_carbon = carbon
		_first_o2 = o2_open
		_first_fert = fert_open
		_first_biomass = bio_open
		_first_step = step_index
	var run_steps: int = step_index - _first_step
	out["mass_run_steps"] = run_steps
	out["carbon_first"] = snappedf(_first_carbon, 0.01)
	out["o2_first"] = snappedf(_first_o2, 0.01)
	out["fert_first"] = snappedf(_first_fert, 0.01)
	out["biomass_first"] = snappedf(_first_biomass, 0.01)
	if run_steps > 0:
		var rinv: float = 1.0 / float(run_steps)
		out["carbon_run_drift_per_step"] = snappedf((carbon - _first_carbon) * rinv, 0.0001)
		out["o2_run_drift_per_step"] = snappedf((o2_open - _first_o2) * rinv, 0.0001)
		out["fert_run_drift_per_step"] = snappedf((fert_open - _first_fert) * rinv, 0.0001)
		out["biomass_run_drift_per_step"] = snappedf((bio_open - _first_biomass) * rinv, 0.0001)
	out["mass_scan_ms"] = snappedf(float(Time.get_ticks_usec() - t0) / 1000.0, 0.01)
	return out


func _blank() -> Dictionary:
	return {
		"carbon_total": 0.0, "carbon_all": 0.0, "carbon_buried": 0.0,
		"carbon_co2": 0.0, "carbon_biomass": 0.0, "carbon_detritus": 0.0,
		"carbon_drift": 0.0, "carbon_drift_per_step": 0.0,
		"o2_total": 0.0, "o2_all": 0.0, "o2_drift": 0.0, "o2_drift_per_step": 0.0,
		"fert_total": 0.0, "fert_all": 0.0, "fert_drift": 0.0, "fert_drift_per_step": 0.0,
		"biomass_open_total": 0.0, "biomass_drift": 0.0, "biomass_drift_per_step": 0.0,
		"fungus_total": 0.0, "fuel_open_total": 0.0,
		"mass_open_cells": 0, "mass_drift_steps": 0, "mass_run_steps": 0, "mass_scan_ms": 0.0,
		"carbon_first": 0.0, "o2_first": 0.0, "fert_first": 0.0, "biomass_first": 0.0,
		"carbon_run_drift_per_step": 0.0, "o2_run_drift_per_step": 0.0,
		"fert_run_drift_per_step": 0.0, "biomass_run_drift_per_step": 0.0,
		"mass_live": {},
	}
