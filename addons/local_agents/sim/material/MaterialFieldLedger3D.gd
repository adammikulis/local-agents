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


## Total frozen H₂O over the field (one leg of the conserved h2o_total).
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


## Total dynamic liquid water over the field (excludes the static sea reservoir; one leg of h2o_total).
func water_total() -> float:
	if _f._water.size() != _f._cell_count:
		return 0.0
	var solid: PackedByteArray = _f._solid
	var stat: PackedByteArray = _f._static
	var water: PackedFloat32Array = _f._water
	var sum: float = 0.0
	for c in _f._cell_count:
		if solid[c] == 0 and stat[c] == 0:          # exclude the static sea reservoir (matches the docstring) —
			sum += water[c]                         # else the infinite-reservoir cells inflate the conserved ledger
	return sum


## Total water stored in the SOIL (ground cells) — the subsurface leg of the conserved h2o budget. Infiltrated
## water lives here rather than in _water, so it must be counted or conservation would appear to leak.
func soil_total() -> float:
	if _f._soil.size() != _f._cell_count:
		return 0.0
	var solid: PackedByteArray = _f._solid
	var soil: PackedFloat32Array = _f._soil
	var sum: float = 0.0
	for c in _f._cell_count:
		if solid[c] != 0:
			sum += soil[c]
	return sum


## Conserved H₂O budget of the DYNAMIC system: liquid water + airborne moisture + frozen snow + SOIL water.
## Freeze/melt/deposition/evap/rain/infiltration are all pure transfers between these, so this stays BOUNDED
## (a slow static-sea source + rain-to-sea sink hold it steady) — the mass-conservation spot check for SIM_REPORT.
func h2o_total() -> float:
	return water_total() + _f.moisture_total() + snow_total() + soil_total()


## Liquid water held in STATIC cells — the sea, the seeded lakes and the seeded river channels.
##
## This is the reservoir h2o_total does NOT count, and not counting it is why the ledger does not balance.
## The four legs disagree about static cells: water_total excludes them (above), while moisture_total
## (LAMaterialFieldAtmos3D) and snow_total (above) include them, and soil_total keys on solidity instead.
## So every transfer that crosses the static boundary mints or destroys ledger mass while the GPU buffers
## themselves stay perfectly conserving — runoff into the sea vanishes (water_sphere3d.glsl absorbs it),
## sea evaporation appears from nowhere (atmos_evap_sphere3d.glsl adds without debiting), and sea ice
## freezing moves uncounted water into counted snow.
##
## Report this ALONGSIDE the other four and the books close: the residual across all five is the true
## non-conserving flux, which is the number to drive to zero.
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


## Soil summed over the REGOLITH mask rather than the solidity mask.
##
## soil_total() above filters on `_solid`, but soil physically lives in `_regolith`, and the two masks
## diverge: world-gen river carving clears `_solid` on cells `_compute_regolith` has already primed
## (LAMaterialFieldLakes3D carves AFTER _compute_regolith runs), and every MineralStamp3D shrink clears
## more at runtime. Those cells keep their soil on the GPU and keep `regolith = 1`, so the kernel goes on
## simulating them — they have simply dropped out of the ledger. The gap between this and soil_total() is
## therefore water the ACCOUNTING lost, not water the planet lost, and it is non-zero from frame 0.
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


## Everything the ledger knows, sampled once: the five reservoirs, the two soil masks, and the per-step
## drift since the previous sample. `h2o_drift_per_step` is the honest conservation figure — a total that
## only ever gets printed as an absolute cannot show a slow leak, which is exactly how this one hid.
## Returns drift 0.0 on the first sample and whenever the step counter has not advanced.
func conservation_report(step_index: int) -> Dictionary:
	var h2o: float = h2o_total()
	var drift: float = 0.0
	var per_step: float = 0.0
	if not is_nan(_prev_h2o) and step_index > _prev_step:
		drift = h2o - _prev_h2o
		per_step = drift / float(step_index - _prev_step)
	_prev_h2o = h2o
	_prev_step = step_index
	return {
		"h2o_static_water": snappedf(static_water_total(), 0.01),
		"h2o_closed_total": snappedf(h2o + static_water_total(), 0.01),
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
