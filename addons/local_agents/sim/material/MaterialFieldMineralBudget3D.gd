class_name LAMaterialFieldMineralBudget3D
extends RefCounted

## LAMaterialFieldMineralBudget3D — THE CONSERVATION LEDGER FOR MINERAL, built to the shape
## LAMaterialFieldLedger3D proved on H₂O and LAMaterialFieldMassBudget3D copied for carbon: a total, its five
## phase legs, and a DRIFT PER FIELD STEP. The drift is the instrument. `mineral_total` is called "the
## unification's proof object" everywhere in this subtree, and until this module it was published as SIX
## ABSOLUTES AND ZERO DELTAS (MaterialFieldReport3D.gd), which cannot show a slow leak and cannot show minting
## at all. Every substance in this simulation that lacked a ledger has turned out to be minting; mineral had
## never been checked.
##
## THE INCLUSION RULE — ONE rule, obeyed by all five legs. **EVERY CELL. No mask.**
##
##   rock_fill (bedrock) · lava (molten) · sediment (loose) · susp (waterborne) · dust (airborne)
##   are five PHASES OF ONE SUBSTANCE, and each is summed over every cell in the grid.
##
## WHY MASK-FREE, and it is a stronger argument than the H₂O ledger's:
##  1. `solid` IS `rock_fill`. LASolidDerivePass re-derives the solid flag from rock_fill >= 0.5 every single
##     step, so masking a mineral leg on `solid` makes the ledger's own membership a function of the very
##     quantity it is measuring. A cell whose rock_fill crosses 0.5 would move mass in or out of the books with
##     NO physical transfer having happened — the ledger's arithmetic read as physics, which is exactly the
##     failure the H₂O ledger's header documents.
##  2. `solid` is a DERIVED, fractional-threshold flag, not an occupancy fact. A cell at rock_fill 0.6 is
##     flagged solid and still has 40% void that holds water, lava, sediment and dust; the kernels put mass
##     there and go on stepping it. Mass exists where its buffer says it exists.
##  3. The four other legs ALREADY summed every cell and each carries its own comment explaining why (a
##     solidified cell keeps its trapped sediment; add_lava injects into a still-solid vent). Only
##     `dust_total` masked on `_solid[c] == 0`, so the five-leg sum was assembled from two different
##     populations. Fixed here and in LAMaterialFieldQueries3D.dust_total on 2026-08-03.
##
## `mineral_open` is kept as a MEMO LINE (the same legs re-summed over open cells only) and
## `mineral_buried` is the difference, so burial stays VISIBLE rather than being silently deleted from the
## books — the pattern LAMaterialFieldMassBudget3D's `*_all` legs established. It is not a second ledger.
##
## SOURCES ARE NOT DRIFT, AND THIS IS WHY THE RAW NUMBER IS THE WRONG ONE TO QUOTE.
## The planet has one admitted mineral SOURCE: LAMaterialFieldInject3D.erupt_source (":296 — the deep reservoir
## is effectively infinite, so mineral_total rises by exactly the mass injected"). That is a physically honest
## model — an erupting vent really does deliver mantle rock from outside the simulated shell — but it means a
## conserving substrate STILL shows a rising `mineral_total`. So this module reports three rates:
##   `mineral_run_drift_per_step`   raw d(total)/d(step). Includes the vent.
##   `mineral_src_per_step`         the vent's own supply rate, read from the injection queue's `mineral_minted`.
##   `mineral_net_per_step`         raw MINUS source — the number that answers "does the SUBSTRATE mint".
## A `mineral_net_per_step` near zero with a positive raw drift is a conserving planet with a working volcano.
## A large `mineral_net_per_step` is a kernel creating or destroying rock, and LA_MINERAL_BUDGET
## (LAMaterialFieldMineralProbe3D) names which pass does it.
##
## STALENESS IS THE TRAP THIS LEDGER MUST NOT FALL INTO, AND THE FIRST FIX FOR IT WAS ITSELF A BUG.
## Four of the five legs are demand-gated on the GPU: `lava`, `dust` and `rock_fill` are SITUATIONAL_CHANNELS
## and `sediment`/`susp` are SLOW_CHANNELS (MaterialSphereGPU3D.gd). A channel nobody requests stops being read
## back and its CPU mirror FREEZES — and a frozen mirror reads as perfect conservation, which is the most
## dangerous possible failure for a conservation gauge.
##
## The first version of this module answered that by calling `request_channel` on all five every sample. **That
## made the instrument change the run.** Residency decides what the CPU mirrors hold, and the field's own write
## paths read those mirrors: `avg_atmos_dust()` turns `_f._dust` into the opacity that sets INSOLATION, so
## waking `dust` switched impact winter on (`dust_total` 0.00 → 181-217, `atmos_transmission` 0.926 → 0.915,
## measured 2026-08-03); `add_lava` pushes the whole `lava`/`rock_fill` mirrors back with `set_field`, so their
## staleness decides how much GPU-evolved mass that upload rewinds; and `LAMineralStamp3D._scan()` reads the
## `rock_fill` mirror to emit SDF stamps. Two of the five requests were also pure noise — `sediment` and `susp`
## are not SITUATIONAL_CHANNELS, so `request_channel` on them did nothing at all.
##
## SO THIS LEDGER REQUESTS NOTHING. It samples the five legs through `LAMaterialSphereGPU3D.request_probe` /
## `take_probe`: the driver reads them INSIDE ITS DRAIN, where the device has just been synced, into a
## dictionary only instruments see. It touches no residency, no mirror, no cache and no cadence counter, so
## nobody else's view of the world changes because a gauge looked. `mineral_live` still says which legs
## arrived, so a leg that never came back is never mistaken for a phase that genuinely holds nothing.
##
## AND THE SAMPLE MUST BE TAKEN AT THE DRAIN, NOT ON THE SPOT. Reading the same buffers with
## `buffer_get_data` from the report path — while a step submit is still in flight — moved `h2o_total`
## 5062 -> 9803 and `temp_mean` 39.8 -> 44.6 C on otherwise identical runs. The full measurement is in
## `request_probe`'s docstring; the short version is that `buffer_get_data` is not a passive read on a local
## RenderingDevice.
##
## WHAT IT FOUND, AND IT IS NOT THE DRIFT. **`dust_total` HAD BEEN REPORTING A DEAD MIRROR.** SIM_REPORT
## printed `dust_total 0.00` and `dust_cells 0` on every run this project has ever taken — a whole phase of the
## "conserved" mineral total that was simply not in the books, about a fifth of the sediment leg. Nothing was
## wrong with the dust kernel; nothing was READING it. It also meant LASystemOrbits._compute_transmission, the
## entire impact-winter mechanism, was dividing by a permanent zero. The fix for THAT belongs to impact winter,
## not here: `LAMaterialFieldQueries3D.avg_atmos_dust()` now requests `dust` itself, so the mechanism works
## whether or not any ledger is running.
##
## AND THE ANSWER TO THE QUESTION THIS MODULE EXISTS TO ASK. 3 runs, `--planet-only --run-frames=600 --fast=8
## --seed=4242 --fixed-fps 60`, 5 impacts / 3 eruptions / 0 bolts each, `field_step` 590 and
## `mineral_run_steps` 760 in all three (re-measured 2026-08-03 with the drain probe in place; the first
## published set was +0.2420/+0.2419/+0.2409 raw and -0.0433/-0.0423/-0.0433 net, taken before
## `avg_atmos_dust()` owned the dust readback, so the airborne leg arrived later in the run):
##   raw   `mineral_run_drift_per_step`  +0.2240 / +0.2230 / +0.2240
##   vent  `mineral_src_per_step`        +0.2860 / +0.2840 / +0.2860
##   NET   `mineral_net_per_step`        **-0.0620 / -0.0610 / -0.0620**
## **MINERAL DOES NOT MINT. IT LEAKS**, at about 0.06 units/step — 47 units over 760 steps against a ~32150
## inventory, -0.15% per run — and the vent's mantle source is four to five times larger, which is exactly why
## a rising absolute total hid it for as long as there was no drift gauge. `LA_MINERAL_BUDGET=1`
## (LAMaterialFieldMineralProbe3D) names the pass: `fire_dust`, at -0.1033/step on the last sample of a
## 600-frame run, with `legs_all` 0.0000 for all eleven others.
##
## COST: ONE O(cells) pass accumulating all ten accumulators at once, on the report's HEAVY cadence gate. It
## REPLACES eleven separate O(cells) scans that ran ungated on the per-frame report path (`mineral_total()`
## alone re-walked the grid five times, and the report then called each of the same five getters again, plus
## `rock_cells`). `mineral_scan_ms` is what one sweep costs.
## (Explicit types only, no ':=' inferred typing.)

var _f = null                                # back-reference to the owning LAMaterialField3D

# Previous sample, for the per-sample drift. NAN until the first sample so the first reading reports no drift
# rather than a spurious one — the convention LAMaterialFieldLedger3D and LAMaterialFieldMassBudget3D share.
var _prev_total: float = NAN
var _prev_step: int = -1

# FIRST sample, and the run-long drift measured against it. The per-sample drift is one short window and so is
# a sample, not a trend: it catches whatever eruption happened to be venting. The run-long figure divides the
# WHOLE change by the WHOLE number of steps, which is the number to quote for "does this substance mint".
var _first_total: float = NAN
var _first_src: float = 0.0
var _first_step: int = -1
var _samples: int = 0

# BASELINE BEDROCK, latched at the same sample the run-long drift baseline is, and the reference `crust_moved`
# measures displacement against. One extra full-grid float array (276 KB at the shipped resolution) and one
# extra accumulator inside the walk this module already does — no second scan.
var _rock_ref: PackedFloat32Array = PackedFloat32Array()
var _rock_ref_step: int = -1

## Samples to discard before latching the run-long BASELINE, and this is not a fudge — it is the fix for a
## measured artifact that this module's own first run produced.
##
## *(Corrected 2026-08-03. This used to read "four of the five legs are demand-gated, so the very first
## `report()` REQUESTS them and then reads the CPU mirrors that have not been refilled yet" — an instrument
## measuring its own warm-up. The mechanism has changed but the shape has not: the drain probe lands one drain
## after it is armed, so the FIRST sample still reads mirrors rather than probe data.)* The skip also guards
## the pre-first-step window: the report path can fire
## before the field has stepped at all, and a baseline latched on world-gen's seeded state books the whole
## initial settling as drift. `mineral_first_step` publishes where the baseline was actually taken, so this is
## checkable rather than trusted — and the tell that it is set wrong is the run-long rate disagreeing in SIGN
## with the per-sample rate (that is exactly how the original artifact was caught: +0.112 against -0.163).
const BASELINE_SKIP_SAMPLES: int = 2

## The five phases of the one substance, in the order the header names them. Read as one device sample.
const LEGS: PackedStringArray = ["rock_fill", "lava", "sediment", "susp", "dust"]


func setup(field) -> void:
	_f = field


## The mineral ledger, sampled in one pass. `step_index` is the field's own step counter — drift is reported
## PER FIELD STEP, never per frame, because these are reservoirs whose value tracks steps taken and a
## frame-based rate would track framerate instead of physics.
func report(step_index: int) -> Dictionary:
	var out: Dictionary = _blank()
	if _f == null or _f._cell_count <= 0:
		return out
	var t0: int = Time.get_ticks_usec()
	var cc: int = _f._cell_count
	var solid: PackedByteArray = _f._solid
	if solid.size() != cc:
		return out
	# THE FIVE LEGS, SAMPLED READ-ONLY. Collect the probe the previous sample armed (taken at a drain, where a
	# device read is free of side effects), then arm the next one. The CPU mirrors stand in until the first
	# probe lands and on a build with no GPU driver (the headless CPU-oracle path), where they ARE the
	# substrate. `mineral_live` says which of the two each leg came from being the right size.
	var legs: Dictionary = {}
	if _f._gpu != null and _f._gpu.has_method("take_probe"):
		legs = _f._gpu.take_probe()
		_f._gpu.request_probe(LEGS)
	var rock: PackedFloat32Array = legs.get("rock_fill", _f._rock_fill)
	var lava: PackedFloat32Array = legs.get("lava", _f._lava)
	var sed: PackedFloat32Array = legs.get("sediment", _f._sediment)
	var susp: PackedFloat32Array = legs.get("susp", _f._susp)
	var dust: PackedFloat32Array = legs.get("dust", _f._dust)
	var has_rock: bool = rock.size() == cc
	var has_lava: bool = lava.size() == cc
	var has_sed: bool = sed.size() == cc
	var has_susp: bool = susp.size() == cc
	var has_dust: bool = dust.size() == cc

	var rock_all: float = 0.0
	var rock_open: float = 0.0
	var lava_all: float = 0.0
	var lava_open: float = 0.0
	var sed_all: float = 0.0
	var sed_open: float = 0.0
	var susp_all: float = 0.0
	var susp_open: float = 0.0
	var dust_all: float = 0.0
	var dust_open: float = 0.0
	var dusty_cells: int = 0
	var solid_cells: int = 0
	var crust_moved: float = 0.0
	var has_ref: bool = _rock_ref.size() == cc
	for c in cc:
		var is_open: bool = solid[c] == 0
		if not is_open:
			solid_cells += 1
		if has_rock:
			var v0: float = rock[c]
			rock_all += v0
			if is_open:
				rock_open += v0
			if has_ref:
				crust_moved += absf(v0 - _rock_ref[c])
		if has_lava:
			var v1: float = lava[c]
			lava_all += v1
			if is_open:
				lava_open += v1
		if has_sed:
			var v2: float = sed[c]
			sed_all += v2
			if is_open:
				sed_open += v2
		if has_susp:
			var v3: float = susp[c]
			susp_all += v3
			if is_open:
				susp_open += v3
		if has_dust:
			var v4: float = dust[c]
			dust_all += v4
			if is_open:
				dust_open += v4
			if v4 > LAMaterialFieldQueries3D.DUST_PRESENT:
				dusty_cells += 1

	var total: float = rock_all + lava_all + sed_all + susp_all + dust_all
	var open_total: float = rock_open + lava_open + sed_open + susp_open + dust_open
	out["mineral_total"] = snappedf(total, 0.01)
	out["mineral_open"] = snappedf(open_total, 0.01)
	out["mineral_buried"] = snappedf(total - open_total, 0.01)
	out["rock_fill_total"] = snappedf(rock_all, 0.01)
	out["lava_total"] = snappedf(lava_all, 0.01)
	out["sediment_total"] = snappedf(sed_all, 0.01)
	out["susp_total"] = snappedf(susp_all, 0.01)
	out["dust_total"] = snappedf(dust_all, 0.01)
	# The one leg whose mask actually changed on 2026-08-03 — published beside the unified figure so the
	# before/after of the inclusion fix is readable straight off a single run, not only across two builds.
	out["dust_open_total"] = snappedf(dust_open, 0.01)
	# SIM_REPORT's `dust_cells`, counted here because this pass already walks the channel. It was
	# `LAMaterialField3D.dust_cell_count() { return 0 }` — a gauge that could only ever print zero. The
	# stop-gap replacement (`LAMaterialFieldQueries3D.dust_cell_count()`, a real body with no caller) was
	# deleted 2026-08-03: this line supersedes it, with the same DUST_PRESENT threshold and no extra grid walk.
	out["dust_cells"] = dusty_cells
	out["rock_cells"] = solid_cells
	# HOW FAR THE CRUST HAS MOVED, which no other gauge can answer. `rock_fill_total` is flat while continents
	# drift, because transport conserves — the mass is the same, it is somewhere else. So compare against the
	# baseline sample cell by cell: `crust_moved` is the total absolute change in bedrock since the run's
	# reference, HALVED, so a unit of rock that leaves one cell and arrives in another counts once rather than
	# twice. It reads as "cells of bedrock relocated". It counts every rock_fill change, not only plate motion
	# (erosion, lava solidifying and impacts all move bedrock too), so isolate the plate leg by A/B against
	# LA_NO_PLATE_ADVECT=1 rather than by reading it alone. `crust_moved_ref_step` says which step the baseline
	# was taken at, for the same reason `mineral_first_step` exists.
	if has_ref:
		out["crust_moved"] = snappedf(crust_moved * 0.5, 0.01)
		out["crust_moved_ref_step"] = _rock_ref_step
	elif has_rock and _samples >= BASELINE_SKIP_SAMPLES:
		_rock_ref = rock.duplicate()
		_rock_ref_step = step_index
	# PROVENANCE. A leg whose mirror never arrived reads as a flat zero, which is indistinguishable from a
	# phase that genuinely holds nothing — and, worse, a frozen mirror reads as perfect conservation.
	out["mineral_live"] = {
		"rock_fill": has_rock, "lava": has_lava, "sediment": has_sed,
		"susp": has_susp, "dust": has_dust,
	}

	# THE ADMITTED SOURCE. erupt_source injects mantle lava with no debit anywhere in the field, so it is
	# booked as `mineral_minted` by the injection queue and must be subtracted before any statement about
	# whether the SUBSTRATE conserves. Read defensively: a build without the inject module still reports.
	var src: float = 0.0
	if _f._inject != null and _f._inject.queue != null:
		src = float(_f._inject.queue.mineral_minted)
	out["mineral_src_total"] = snappedf(src, 0.01)

	# DRIFT — the whole point. Per FIELD STEP, against the previous sample.
	var steps: int = step_index - _prev_step
	if steps > 0 and _prev_step >= 0 and not is_nan(_prev_total):
		out["mineral_drift"] = snappedf(total - _prev_total, 0.01)
		out["mineral_drift_per_step"] = snappedf((total - _prev_total) / float(steps), 0.0001)
		out["mineral_drift_steps"] = steps
	if steps > 0 or _prev_step < 0:
		_prev_total = total
		_prev_step = step_index
	# RUN-LONG DRIFT — the headline conservation figure, and its source-corrected twin. The baseline is latched
	# only after the demand-gated mirrors have arrived (see BASELINE_SKIP_SAMPLES).
	_samples += 1
	if _first_step < 0 and _samples > BASELINE_SKIP_SAMPLES:
		_first_total = total
		_first_src = src
		_first_step = step_index
	var run_steps: int = step_index - _first_step if _first_step >= 0 else 0
	out["mineral_run_steps"] = run_steps
	out["mineral_samples"] = _samples
	out["mineral_first_step"] = _first_step
	out["mineral_first"] = snappedf(_first_total if not is_nan(_first_total) else 0.0, 0.01)
	if run_steps > 0:
		var rinv: float = 1.0 / float(run_steps)
		out["mineral_run_drift_per_step"] = snappedf((total - _first_total) * rinv, 0.0001)
		out["mineral_src_per_step"] = snappedf((src - _first_src) * rinv, 0.0001)
		# THE ANSWER TO "DOES MINERAL MINT": raw drift with the vent's declared supply removed.
		out["mineral_net_per_step"] = snappedf(((total - _first_total) - (src - _first_src)) * rinv, 0.0001)
	out["mineral_scan_ms"] = snappedf(float(Time.get_ticks_usec() - t0) / 1000.0, 0.01)
	return out


func _blank() -> Dictionary:
	return {
		"mineral_total": 0.0, "mineral_open": 0.0, "mineral_buried": 0.0,
		"rock_fill_total": 0.0, "lava_total": 0.0, "sediment_total": 0.0,
		"susp_total": 0.0, "dust_total": 0.0, "dust_open_total": 0.0, "dust_cells": 0, "rock_cells": 0,
		"mineral_drift": 0.0, "mineral_drift_per_step": 0.0, "mineral_drift_steps": 0,
		"mineral_run_steps": 0, "mineral_first": 0.0, "mineral_run_drift_per_step": 0.0,
		"mineral_samples": 0, "mineral_first_step": -1,
		"mineral_src_total": 0.0, "mineral_src_per_step": 0.0, "mineral_net_per_step": 0.0,
		"mineral_scan_ms": 0.0, "mineral_live": {},
		"crust_moved": 0.0, "crust_moved_ref_step": -1,
	}
