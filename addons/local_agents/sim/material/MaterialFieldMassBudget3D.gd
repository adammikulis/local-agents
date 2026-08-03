class_name LAMaterialFieldMassBudget3D
extends RefCounted

## LAMaterialFieldMassBudget3D — CONSERVATION LEDGERS FOR CARBON, OXYGEN, FERTILITY AND BIOMASS, built to the
## shape LAMaterialFieldLedger3D already proved on H₂O: a total per substance, and a DRIFT PER FIELD STEP
## against the previous sample. The drift is the instrument. A total printed as an absolute cannot show a slow
## leak — that is exactly how the water leak hid — and it cannot show minting at all.
##
## WHY THESE FOUR AND WHY NOW. The correlation was hard to miss once someone looked: every substance that HAD
## a ledger conserved, and every substance without one created matter. H₂O had `h2o_total`,
## `h2o_drift_per_step` and per-pass probes, and its transfers were real transfers. Minerals had
## `mineral_total`. Carbon, oxygen and fertility had NOTHING — a grep for carbon_total / co2_total / o2_total
## under sim/material/ returned zero — and all three created matter from nothing.
##
## ALL THREE OF THOSE DEFECTS ARE FIXED AS OF 2026-08-03, and what they were is kept here because the
## instrument's whole justification is that it was the thing that measured them. **Do not read the list below
## as a description of live code.**
##   * CARBON had no source pool at all. `_co2` was allocated and NOT filled — the line above it filled `_o2`
##     with O2_AMBIENT, so the omission was visible in the diff — and the planet's entire carbon inventory
##     then arrived through ONE record, R12, which used a rate model carrying no reactant list at all while
##     reactions_sphere3d.glsl skipped the reactant-cap block for it. A tap with no tank behind it. NOW: the
##     atmosphere is seeded finite at Earth's measured composition, R11/R12 and the rate model are deleted,
##     and this ledger measured the result — `carbon_run_drift_per_step` +6.49 -> -0.024.
##   * OXYGEN gained on every turn of the carbon cycle: photosynthesis yielded 1.0 O₂ per carbon fixed while
##     respiration spent 0.5 and decomposition 0.8 against 1.0 CO₂. The two directions are chemical inverses
##     and their coefficients were not equal, so each cycle left free oxygen behind. NOW: the identity is
##     enforced per record by LAReactionBalance's `oxidant` sum, not by two constants set equal by hand.
##   * FERTILITY was created at roughly 75:1 per unit of extent (1.5 produced against 0.02 consumed) with no
##     source pool on either side. NOW: organic matter is declared to CARRY nitrogen at the measured litter
##     C:N ratio, and release, uptake and litterfall all derive from that one declaration.
## A drift that comes back non-zero is still the correct result to report, not a bug in the meter.
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
## (0.6 + 0.4 = 1), R15 rots 1 detritus into 1 CO₂. So any drift in this sum is a kernel outside the reaction
## table. FUEL and FUNGUS are carbon-bearing in the real world but are moved by their own kernels
## (fire_sphere3d, fungus_sphere3d) with no stoichiometric link to this triangle, so keeping them out is what
## lets a leak be LOCALISED to one side or the other. They are reported beside the total as memo lines, and
## summed into `carbon_closed_total` below, which is the conservation claim.
##
## OXYGEN'S CONVENTION: `o2_total` is FREE molecular O₂ only — the `o2` channel — and NOT the oxygen bound in
## CO₂. That is still the right thing to publish for "how much air is there to breathe", but as a
## CONSERVATION gauge it is the wrong shape and always was, because free O₂ is not a conserved quantity:
## photosynthesis and respiration trade it against the oxygen bound in CO₂ all day, so a healthy biosphere
## makes `o2_total` wander for entirely honest reasons.
##
## THE CONSERVED QUANTITY IS `oxidant_total` = o2 + co2, ADDED 2026-08-03. One unit of free O₂ and one unit
## of CO₂ each carry one O₂-equivalent of oxidising capacity (a fully oxidised carbon has one O₂ bound into
## it; reduced carbon has none), so every oxidation and every reduction in the reaction table moves that
## capacity between the two pools and conserves the sum. LAReactionBalance enforces exactly this identity per
## record, which is what makes the gauge meaningful: any drift in `oxidant_total` is now provably OUTSIDE the
## reaction table. The old note said counting bound oxygen "would import a stoichiometry the substrate does
## not implement" — the substrate implements it now, and it is the same identity BioRecords.gd was already
## asserting in prose ("O₂ consumed == CO₂ produced") and enforcing by hand.
##
## AND `carbon_closed_total` = co2 + biomass + detritus + fungus + fuel, ADDED for the same reason. The note
## below is right that the three-slot triangle is what the REACTION TABLE moves, and that keeping the memo
## lines separate is what let R12's signature stand out. But fungus and fuel are carbon in the real world,
## and a carbon ledger that omits two carbon pools cannot answer "is carbon conserved" — only "is carbon
## conserved among the slots I chose to look at". Measured on the run that added this: `carbon_total` fell
## 18.8 units while `fungus_total` rose 58, so the narrow total showed a small leak where the wide one shows
## a net gain. Both are published; the narrow one localises, the wide one is the conservation claim.
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
#
## AND THE BASELINE MUST NOT BE TAKEN BEFORE ITS LEGS ARRIVE. Until 2026-08-03 every `_first_*` was captured
## on the very FIRST call, and on that call the device probe armed in `report()` has not landed yet, so every
## leg fell back to a CPU mirror — and `co2`, `detritus` and `fungus` are demand-gated (never read back
## unless something asks) while `biomass` is a slow channel. The measured consequence: `carbon_first` read
## exactly 720.00 in every run of every arm, which is the seeded soil detritus and nothing else, with no CO₂
## and no biomass in it. Every `carbon_run_drift_per_step` ever quoted from this gauge was therefore measured
## against a baseline that omitted the atmosphere. Each quantity now waits for its OWN legs and records its
## own first step, so a baseline is a real measurement or it is not taken at all.
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
	# THE TWO GAUGES THAT ARE ACTUALLY CONSERVED (see the header). `oxidant_total` is the O₂-equivalent sum
	# the reaction table provably holds; `carbon_closed_total` is carbon over EVERY pool that carries it, not
	# only the three the reaction table moves between.
	var oxidant: float = o2_open + co2_open
	var carbon_closed: float = carbon + fung_open + fuel_open
	# NITROGEN, over every pool that holds it. `fert_total` alone answers "how much nutrient can a plant take
	# up", which is a useful number and NOT a conservation gauge: mineral N and organic N trade places all
	# day, so a healthy soil makes `fert_total` wander for honest reasons. The conserved quantity is the sum,
	# and it is conserved for a structural reason rather than a tuned one — LAReactionBalance declares organic
	# matter to carry nitrogen at the measured litter C:N ratio, and every record is checked against that one
	# declaration, so the release coefficient in R15, the uptake coefficient in R19 and the litterfall
	# coefficient in R20 cannot disagree.
	var nitrogen: float = fert_open + (bio_open + det_open + fung_open + fuel_open) / LAPhysical.LITTER_C_TO_N
	out["oxidant_total"] = snappedf(oxidant, 0.01)
	out["carbon_closed_total"] = snappedf(carbon_closed, 0.01)
	out["nitrogen_total"] = snappedf(nitrogen, 0.01)

	# RUN-LONG DRIFT — the headline conservation figure. The first sample is the baseline; everything after is
	# measured against it over the field steps actually elapsed. Each quantity takes its baseline only once
	# ITS OWN legs have arrived from the device (see the note on `_first_*` above); until then it reports no
	# baseline at all rather than a mirror artefact.
	var run_steps: int = 0
	if has_co2 and has_bio and has_det:
		if _first_carbon_step < 0:
			_first_carbon = carbon
			_first_carbon_step = step_index
		run_steps = step_index - _first_carbon_step
		out["carbon_first"] = snappedf(_first_carbon, 0.01)
		if run_steps > 0:
			out["carbon_run_drift_per_step"] = snappedf((carbon - _first_carbon) / float(run_steps), 0.0001)
	if has_o2:
		if _first_o2_step < 0:
			_first_o2 = o2_open
			_first_o2_step = step_index
		out["o2_first"] = snappedf(_first_o2, 0.01)
		if step_index > _first_o2_step:
			out["o2_run_drift_per_step"] = snappedf(
				(o2_open - _first_o2) / float(step_index - _first_o2_step), 0.0001)
	if has_fert:
		if _first_fert_step < 0:
			_first_fert = fert_open
			_first_fert_step = step_index
		out["fert_first"] = snappedf(_first_fert, 0.01)
		if step_index > _first_fert_step:
			out["fert_run_drift_per_step"] = snappedf(
				(fert_open - _first_fert) / float(step_index - _first_fert_step), 0.0001)
	if has_bio:
		if _first_biomass_step < 0:
			_first_biomass = bio_open
			_first_biomass_step = step_index
		out["biomass_first"] = snappedf(_first_biomass, 0.01)
		if step_index > _first_biomass_step:
			out["biomass_run_drift_per_step"] = snappedf(
				(bio_open - _first_biomass) / float(step_index - _first_biomass_step), 0.0001)
	if has_o2 and has_co2:
		if _first_oxidant_step < 0:
			_first_oxidant = oxidant
			_first_oxidant_step = step_index
		out["oxidant_first"] = snappedf(_first_oxidant, 0.01)
		if step_index > _first_oxidant_step:
			out["oxidant_run_drift_per_step"] = snappedf(
				(oxidant - _first_oxidant) / float(step_index - _first_oxidant_step), 0.0001)
	if has_co2 and has_bio and has_det and has_fung and has_fuel:
		if _first_closed_step < 0:
			_first_closed = carbon_closed
			_first_closed_step = step_index
		out["carbon_closed_first"] = snappedf(_first_closed, 0.01)
		if step_index > _first_closed_step:
			out["carbon_closed_run_drift_per_step"] = snappedf(
				(carbon_closed - _first_closed) / float(step_index - _first_closed_step), 0.0001)
	if has_fert and has_bio and has_det and has_fung and has_fuel:
		if _first_nitrogen_step < 0:
			_first_nitrogen = nitrogen
			_first_nitrogen_step = step_index
		out["nitrogen_first"] = snappedf(_first_nitrogen, 0.01)
		if step_index > _first_nitrogen_step:
			out["nitrogen_run_drift_per_step"] = snappedf(
				(nitrogen - _first_nitrogen) / float(step_index - _first_nitrogen_step), 0.0001)
	out["mass_run_steps"] = run_steps
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
		"oxidant_total": 0.0, "oxidant_first": 0.0, "oxidant_run_drift_per_step": 0.0,
		"carbon_closed_total": 0.0, "carbon_closed_first": 0.0,
		"carbon_closed_run_drift_per_step": 0.0,
		"nitrogen_total": 0.0, "nitrogen_first": 0.0, "nitrogen_run_drift_per_step": 0.0,
		"mass_live": {},
	}
