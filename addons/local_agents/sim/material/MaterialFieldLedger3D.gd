class_name LAMaterialFieldLedger3D
extends RefCounted

## LAMaterialFieldLedger3D: the conserved H₂O LEDGER of LAMaterialField3D (plus the snow/ice diagnostics it
## is built from), factored out of the extract-only field hub. Same pattern as the query / atmos / scent
## modules: it holds no state of its own and reaches into the owning field `_f` for the shared channels.
##
## There is ONE conserved water substance stored in four phase channels: liquid `_water`, airborne
## `_moisture`, frozen `_snow`, subsurface `_soil`. Freeze / melt / deposition / evaporation / rain /
## infiltration are all pure TRANSFERS between them, so their sum (`h2o_total`) must stay BOUNDED: that is
## the mass-conservation spot check the SIM_REPORT prints. Snow and ice are the same channel read at two
## depths (SNOW_PRESENT = covered, ICE_DEPTH = glacial), not two buffers.
##
## THE INCLUSION RULE — ONE rule, obeyed by every leg (unified 2026-07-30; before that all four disagreed).
##
##   A cell counts toward a channel's total if and only if THE CHANNEL PHYSICALLY LIVES THERE:
##     `_water` · `_moisture` · `_snow`  ->  every OPEN cell (`_solid[c] == 0`), static ones INCLUDED.
##     `_soil`                           ->  every REGOLITH cell (`_regolith[c] != 0`), NOT every solid cell.
##                                           Bedrock under the regolith band holds no soil, and a regolith
##                                           cell whose solidity was carved or eroded away still HOLDS and
##                                           still SIMULATES its soil — soil_sphere3d.glsl:223 keys on
##                                           regolith, not solidity, so the kernel keeps stepping it.
##
##   Nothing else narrows a leg. In particular the STATIC flag is NOT an accounting filter: it marks the
##   sea/lake cells whose `_water` the kernels treat as an infinite reservoir, which is a claim about what
##   is SIMULATED, not about what EXISTS. `static_water_total()` reports that subset as a memo line and
##   SIM_REPORT's `h2o_dynamic_total` is the remainder, so nothing is lost by counting the sea in.
##
## WHY IT HAD TO BECOME ONE RULE. The four legs used four different predicates, so any transfer crossing a
## boundary that one leg respected and another ignored MINTED or DESTROYED ledger mass while the GPU buffers
## stayed perfectly conserving — the ledger's own disagreement was being read as physics. Concretely, before
## this: `water_total` excluded static cells while `snow_total` and `moisture_total` included them, so sea
## ice freezing moved uncounted water into counted snow (mass from nowhere) and its melt destroyed it again;
## and `soil_total` keyed on solidity, so carved-river and eroded regolith cells dropped out of the books
## while the kernel went on simulating them.
##
## Unifying makes the residual LARGER, not smaller, and that is the point: `h2o_drift_per_step` now measures
## the true non-conserving flux of the closed system (runoff the sea absorbs, evaporation the sea does not
## debit) instead of a mixture of that flux and the accounting's own boundary errors.
##
## NOISE FLOOR — read these gauges knowing it, or you will attribute weather to your patch. Disasters draw from
## the Godot global RNG rather than LASimRng, so two runs at ONE seed diverge physically. Measured 2026-07-30,
## same build, `--sandbox --seed=4242 --fast=2 --run-frames=300`, both sampled at field_step 1546:
## h2o_closed_total 13615.06 vs 13807.19 — a 1.41% spread, with creatures 19 vs 23 and static_cells 3454 vs
## 3490. Nothing below about 1.5% is resolvable by comparing two runs, so a change this size must be argued
## structurally or measured IN-RUN (see LAMaterialFieldPhotoStats3D's root_col_open_* gauges for that pattern).
##
## Every method here is a pure getter over the GPU readback: O(cells) scans polled at snapshot time, never
## per frame. (Explicit types only, no ':=' inferred typing.)

var _f = null                                            # back-reference to the owning LAMaterialField3D

# DRIFT TRACKING — the one piece of state this module keeps, and it earns its place. Before this existed
# nothing in the project measured whether water is conserved: SIM_REPORT printed four absolute totals with
# no deltas, and scripts/smoke_check.sh only asserts h2o_total is finite and NON-ZERO, so a run that lost
# half the planet's water passed every gate. Measured 2026-07-30 at --fast=2: h2o_total fell 6.4% per 0.4
# simulated days on one build and ROSE 1.4% on another. A conservation law nothing checks is a claim, not a
# law. `_prev_*` are -1/NAN until the first sample so the first reading reports no drift rather than a
# spurious one.
var _prev_h2o: float = NAN
var _prev_step: int = -1


func setup(field) -> void:
	_f = field


## Snow depth at a world point (frozen H₂O in the cell). 2.5D-style (x,z) calls have no radial point, so they
## return the safe default 0 (matching temp_at); a full 3D call (x,z,y) reads the real cell — three-d-always.
func snow_depth_at(pos: Vector3) -> float:
	if _f._snow.size() != _f._cell_count:
		return 0.0
	var c: int = _f.world_to_cell(pos)
	return _f._snow[c] if c >= 0 else 0.0


## Open cells carrying a snowpack (frozen H₂O over SNOW_PRESENT) — the emergent snow-line count for SIM_REPORT.
func snow_cell_count() -> int:
	if _f._snow.size() != _f._cell_count:
		return 0
	var solid: PackedByteArray = _f._solid
	var snow: PackedFloat32Array = _f._snow
	var n: int = 0
	for c in _f._cell_count:
		if solid[c] == 0 and snow[c] > LAMaterialField3D.SNOW_PRESENT:
			n += 1
	return n


## Cells whose pack is thick enough to read as glacial ICE (deep end of the SAME _snow channel, no separate buffer).
func ice_cell_count() -> int:
	if _f._snow.size() != _f._cell_count:
		return 0
	var solid: PackedByteArray = _f._solid
	var snow: PackedFloat32Array = _f._snow
	var n: int = 0
	for c in _f._cell_count:
		if solid[c] == 0 and snow[c] >= LAMaterialField3D.ICE_DEPTH:
			n += 1
	return n


## Total frozen H₂O over the field (one leg of the conserved h2o_total). Inclusion rule: every OPEN cell,
## static ones included — snow on sea ice is real snow.
func snow_total() -> float:
	if _f._snow.size() != _f._cell_count:
		return 0.0
	var solid: PackedByteArray = _f._solid
	var snow: PackedFloat32Array = _f._snow
	var sum: float = 0.0
	for c in _f._cell_count:
		if solid[c] == 0:
			sum += snow[c]
	return sum


## Total liquid water over the field — EVERY open cell, static sea/lake reservoir INCLUDED (the one inclusion
## rule in the header). The static subset is still readable on its own as `static_water_total()`, and the old
## sea-excluded figure as SIM_REPORT's `h2o_dynamic_total`; what is gone is a leg that had its own private idea
## of which cells exist. Excluding the sea here while `snow_total`/`moisture_total` included it is precisely
## what let a freeze at the shoreline create ledger mass from nothing.
##
## CONSUMER NOTE: LAEventTracker's "flood" detector reads `water_total` in `rate` mode — (cur-prev)/dt — so
## the sea's near-constant contribution cancels in the delta and widening this leg does not move that bar.
## (Measured: static water drifted 2771 -> 2693 over 800 field steps, about -0.1/step, against a 40/s bar.)
func water_total() -> float:
	if _f._water.size() != _f._cell_count:
		return 0.0
	var solid: PackedByteArray = _f._solid
	var water: PackedFloat32Array = _f._water
	var sum: float = 0.0
	for c in _f._cell_count:
		if solid[c] == 0:
			sum += water[c]
	return sum


## Total water stored in the SOIL — the subsurface leg of the conserved h2o budget. Infiltrated water lives
## here rather than in `_water`, so it must be counted or conservation would appear to leak.
##
## Masked on REGOLITH, which is where soil physically lives, and NOT on solidity, which is where this leg used
## to look. The two masks diverge from frame 0 and keep diverging: world-gen river carving clears `_solid` on
## cells `_compute_regolith` already primed (LAMaterialFieldLakes3D carves AFTER it runs —
## MaterialFieldSphereStep3D.gd:63-64), SolidDerivePass re-derives `_solid` from `rock_fill` every step while
## `regolith` is seeded once and never updated (MaterialSphereGPU3D.gd:37), and every MineralStamp3D shrink
## clears more. Those cells keep their soil on the GPU and keep `regolith = 1`, so soil_sphere3d.glsl goes on
## simulating them — they had simply dropped out of the books. Measured gap before the fix: 3565.38 solid-
## masked vs 3580.68 regolith-masked at field_step 746, 0.43%, present from the first sample.
func soil_total() -> float:
	return regolith_soil_total()


## The planet's WHOLE H₂O budget: liquid water (sea included) + airborne moisture + frozen snow + soil water.
## Freeze/melt/deposition/evap/rain/infiltration are all pure transfers between these four, so this stays
## BOUNDED — the mass-conservation spot check for SIM_REPORT.
##
## This is now a CLOSED sum: with the inclusion rule unified there is no fifth reservoir sitting outside it,
## which is why `h2o_closed_total` reports the same number. It used to be the sea-EXCLUDED subtotal, and that
## series continues in SIM_REPORT as `h2o_dynamic_total` (h2o_total - static_water_total, computed once in
## conservation_report from values it has already sampled) so the pre-unification baselines stay comparable.
func h2o_total() -> float:
	return water_total() + _f.moisture_total() + snow_total() + soil_total()


## Liquid water held in STATIC cells — the sea, the seeded lakes and the seeded river channels.
##
## A MEMO LINE, not a fifth reservoir: `water_total()` already counts these cells, so this is a subset of it,
## reported separately because "how much of the ledger is the sea abstraction" is worth seeing. It is what
## SIM_REPORT's `h2o_dynamic_total` subtracts.
##
## It was previously the reservoir the ledger did NOT count, and that omission — one leg excluding static
## cells while two others included them — was the accounting half of the imbalance. The PHYSICAL half is
## still here and is what the drift now measures honestly: runoff into the sea vanishes
## (water_sphere3d.glsl absorbs it) and sea evaporation appears from nowhere (atmos_evap_sphere3d.glsl adds
## to moisture without debiting the sea). Driving THAT residual to zero is the remaining work; it belongs to
## the static mask itself, not to this module.
func static_water_total() -> float:
	if _f._water.size() != _f._cell_count or _f._static.size() != _f._cell_count:
		return 0.0
	var solid: PackedByteArray = _f._solid
	var stat: PackedByteArray = _f._static
	var water: PackedFloat32Array = _f._water
	var sum: float = 0.0
	for c in _f._cell_count:
		if solid[c] == 0 and stat[c] != 0:
			sum += water[c]
	return sum


## How many cells are held static. Sizes the dynamic-sea change: these are the cells that start being
## simulated, and they are ALREADY being dispatched every step (every kernel runs the full grid and the
## static ones early-out), so this counts new physics work, not new dispatches.
func static_cell_count() -> int:
	if _f._static.size() != _f._cell_count:
		return 0
	var solid: PackedByteArray = _f._solid
	var stat: PackedByteArray = _f._static
	var n: int = 0
	for c in _f._cell_count:
		if solid[c] == 0 and stat[c] != 0:
			n += 1
	return n


## Soil summed over the REGOLITH mask — the canonical implementation of the soil leg; `soil_total()` is this.
##
## The two names are kept deliberately and they report the SAME number by construction. That identity is the
## verifiable form of the fix: `soil_total` vs `soil_regolith_total` in SIM_REPORT used to differ by ~0.43%
## and now agree exactly, so anyone re-deriving the masks can read the answer straight off the report instead
## of trusting this comment. If they ever diverge again, someone has re-introduced a second mask.
func regolith_soil_total() -> float:
	if _f._soil.size() != _f._cell_count or _f._regolith.size() != _f._cell_count:
		return 0.0
	var regolith: PackedByteArray = _f._regolith
	var soil: PackedFloat32Array = _f._soil
	var sum: float = 0.0
	for c in _f._cell_count:
		if regolith[c] != 0:
			sum += soil[c]
	return sum


## Everything the ledger knows, sampled once: the whole budget, its sea/dynamic split, the soil cross-check,
## and the per-step drift since the previous sample. `h2o_drift_per_step` is the honest conservation figure —
## a total that only ever gets printed as an absolute cannot show a slow leak, which is exactly how this one
## hid. Returns drift 0.0 on the first sample and whenever the step counter has not advanced.
##
## `h2o_closed_total` is now IDENTICAL to `h2o_total` and that is the headline result, not a redundancy: the
## legs no longer disagree about which cells exist, so there is nothing left outside the sum to add back. It
## keeps its key so its baseline series stays comparable across the change (it was the only gauge that was
## already counting everything). Drift is measured on that closed total, so it reports the real
## non-conserving flux rather than the old mixture of flux and boundary mis-accounting.
func conservation_report(step_index: int) -> Dictionary:
	var h2o: float = h2o_total()
	var static_water: float = static_water_total()
	var drift: float = 0.0
	var per_step: float = 0.0
	if not is_nan(_prev_h2o) and step_index > _prev_step:
		drift = h2o - _prev_h2o
		per_step = drift / float(step_index - _prev_step)
	_prev_h2o = h2o
	_prev_step = step_index
	return {
		"h2o_static_water": snappedf(static_water, 0.01),
		"h2o_dynamic_total": snappedf(h2o - static_water, 0.01),
		"h2o_closed_total": snappedf(h2o, 0.01),
		"h2o_drift": snappedf(drift, 0.01),
		"h2o_drift_per_step": snappedf(per_step, 0.001),
		"soil_regolith_total": snappedf(regolith_soil_total(), 0.01),
		"static_cells": static_cell_count(),
	}


## Mean temperature over the snow-covered cells — proves snow sits on the COLD side (should read below FREEZE_TEMP).
func snow_line_temp() -> float:
	if _f._snow.size() != _f._cell_count:
		return 0.0
	var solid: PackedByteArray = _f._solid
	var snow: PackedFloat32Array = _f._snow
	var temp: PackedFloat32Array = _f._temp
	var sum: float = 0.0
	var n: int = 0
	for c in _f._cell_count:
		if solid[c] == 0 and snow[c] > LAMaterialField3D.SNOW_PRESENT:
			sum += temp[c]
			n += 1
	return sum / float(n) if n > 0 else 0.0
