class_name LAMaterialFieldH2OBudget3D
extends RefCounted

## LAMaterialFieldH2OBudget3D: a PER-PASS mass budget for the whole conserved H₂O ledger, so a water drain has
## to name the pass that causes it instead of being argued about. Diagnostic only — created by
## LAMaterialFieldSphereStep3D and only when `LA_H2O_BUDGET` is in the environment, because a sampled step
## costs one CPU↔GPU round-trip per pass plus a handful of full-grid readbacks.
##
## WHY PER-PASS AND NOT PER-KERNEL PROBE SLOTS. The soil budget (LAMaterialFieldSoilBudget3D) put 20 dbg slots
## inside soil_sphere3d.glsl because it had to separate legs WITHIN one kernel. Naming which of the twelve
## passes loses water needs nothing that fine, and the cheap form is strictly better evidence: each leg here is
## a DIFFERENCE OF MEASURED BUFFER STATE, read straight off the device between two passes. So the legs sum to
## the step's total change BY CONSTRUCTION — there is no restatement of any kernel's arithmetic in GDScript
## that could itself be wrong, and a pass added tomorrow is instrumented for free.
##
## THE FOUR CHANNELS ARE ONE SUBSTANCE. liquid `water` + airborne `moisture` + frozen `snow` + subsurface
## `soil`. Every transfer the substrate performs (evaporate, precipitate, rain, freeze, melt, infiltrate,
## spring, seep, root-uptake) moves H₂O BETWEEN these four, so a pass that is conserving shows `d_sum` ≈ 0
## however large its individual `d_water` / `d_moisture` are. A pass with a nonzero `d_sum` is creating or
## destroying water, and its magnitude is the answer in units/step.
##
## TWO MASKS, AND THE DIFFERENCE BETWEEN THEM IS ITSELF A RESULT.
##   `open` — water/moisture/snow over OPEN cells (solid == 0), soil over REGOLITH cells. This is exactly the
##            inclusion rule LAMaterialFieldLedger3D uses, so `open.total` is comparable to SIM_REPORT's
##            `h2o_closed_total` (one readback cadence apart).
##   `all`  — the same four channels summed over EVERY cell, mask-free.
## A pass that leaves `all` flat while `open` falls has not destroyed water: it has BURIED it, by turning a
## cell solid (SolidDerivePass re-derives `solid` from rock_fill every step) with water still in it. water
## _sphere3d.glsl's pass 1 passes a solid cell's water through untouched, so buried water is still in the
## buffer, still invisible to the ledger, and never comes back unless the cell melts or is carved open. That
## is a completely different bug from a kernel dropping mass, and no single-masked total can tell them apart.
##
## `open` here uses the GPU's DERIVED solid mask; LAMaterialFieldLedger3D uses the CPU mirror `_f._solid`, and
## the two are not the same mask. `solid` is never read back — the CPU copy is written only by
## _sample_solidity_sphere() and MineralStamp3D's scan, while SolidDerivePass rewrites the device copy from
## rock_fill every step and _seed_solid() uploads the CPU copy over it whenever `_solid_dirty`. The fight is
## visible in the numbers: `chain` catches the upload as a jump of -779.49 / -469.87 / -402.66 between two
## consecutive steps, and the very next `solid_derive` leg undoes it (+790.54 / +471.83 / +436.90). What does
## not undo is the standing disagreement, which is why `open_total` here reads 432 / 1102 / 460 units above
## SIM_REPORT's `h2o_closed_total` at the same horizon. Prefer this module's number: the kernels all gate on
## the device mask, so it is the one the physics actually uses.
##
## WHICH HALF IS CURRENT. Every H₂O pair channel is written exactly once per step, live → back, by one
## PRODUCER pass; every later pass edits `back` in place; the end-of-step parity flip promotes back to live.
## So the current half at a checkpoint is `live` before the producer has run and `back` after — three
## transitions in the whole step, keyed by pass NAME below so a reordering of PASS_SCRIPTS cannot silently
## invalidate this. `snow` is a SINGLE buffer with no halves at all.
##
## THE SELF-CHECK. `residual` is zero by construction (telescoping differences), which is worth nothing on its
## own, so the instrument samples steps in CONSECUTIVE PAIRS: `chain` is the second sample's opening total
## minus the first sample's closing total. If the half-mapping above were wrong, or the parity flip did not do
## what this file claims, the opening read would land on a stale buffer and `chain` would be large. It is the
## only number here that can falsify the instrument, which is why the pairing costs its extra sampled step.
##
## WHAT IT MEASURED, 2026-07-30, seed 4242, --fast=2, 150 frames, quoted at field_step 767.
##
## The world is SEEDED with 7485.40 units of H₂O and every run opens there: water 3483.78 (the sea cells at
## mass 1.0), soil 3997.07 (13323 regolith cells x the 0.3 world-gen seed), moisture 4.55, snow 0.
##
##   run   impacts/eruptions   all_total 1 -> 767      buried   open_total   SIM_REPORT h2o_closed_total
##    1          4 / 3        7485.40 -> 7482.36      1387.45     6094.91          5662.85
##    2          0 / 0        7485.40 -> 7485.40      1755.00     5730.40          4628.39
##    3          4 / 3        7485.40 -> 7478.45      1197.77     6280.68          5820.97
##
## So the substrate loses between 0.00 and 6.95 units of H₂O in 766 steps — 0.00% to 0.09% — across a disaster
## spread of 0 to 4 impacts. `legs_all` is 0.0000 for all twelve passes at every sample in all three runs: no
## pass creates or destroys water. `legs_open` is 0.0000 for all of them too, except `solid_derive`. Nothing
## moves H₂O into bedrock; only the mask moves.
##
## The ledger's decline is therefore entirely BURIAL, and it is mostly MOISTURE, not sea water: at field_step
## 767 the buried 1197-1755 splits as moisture 1020.96-1562.94, water 164.61-183.55, snow 5.97-8.51, soil off
## the regolith mask exactly 0.00. Water in a cell whose rock_fill crosses 0.5 stops being counted and stops
## being simulated (every kernel early-outs on solid), and MineralStamp3D._settle_h2o only displaces the
## subset its throttled, budgeted CPU scan happens to catch.
##
## AND THE BASELINE THIS WAS BEING COMPARED AGAINST IS NOT CONSERVED WATER. Restoring `_static[c] = 1` in
## _seed_sphere_sea for one run (nothing else changed) reproduces the static-sea arm: all_total 7488.26 at
## step 1 -> 13751.54 at step 767, +6263.28 MINTED, with SIM_REPORT h2o_closed_total 13750.05 /
## h2o_static_water 2629.25 / static_cells 3436 at 4 impacts and 3 eruptions. The instrument names the leg
## directly: `atmosphere` runs +6.61/step at field_step 409 and tapers to +0.33/step by 767 as the humidity
## brake engages, against `water_slump_lava` at -0.15 to -1.22/step (runoff the static sea absorbs). That is
## atmos_evap_sphere3d.glsl's `added += e * static_brake` with no matching debit, and it is the whole of the
## "5600-7000 missing units" the dynamic sea was suspected of losing. The static build did not hold that
## water; it made it.
##
## This is also the instrument's real acceptance test. On a build that genuinely fails to conserve, the legs
## are large and named; on this branch they are zero. A budget that only ever prints zeros has not been shown
## to work.
##
## (Explicit types only, no ':=' inferred typing.)

## Field steps between sampled PAIRS. Every 50 puts a line either side of the horizons the dynamic-sea water
## loss was measured at, and 2 of every 50 steps paying the round-trips is a cost the run does not notice.
const SAMPLE_EVERY: int = 50

## Pass names (LAMaterialSphereGPU3D._pass_names = the script basename) at which each pair channel's current
## half switches from live to back. Matched by name, not index: see the header.
const WATER_PRODUCER: String = "WaterSlumpLavaPass"
const MOISTURE_PRODUCER: String = "AtmospherePass"
const SOIL_PRODUCER: String = "SoilPass"

var _f = null                     # back-reference to the owning LAMaterialField3D
# Primed so the FIRST pair samples at field_step 1. The world's opening H₂O total is the number that separates
# "this run lost water" from "this build started with less water", and sampling first at step 50 cannot tell
# them apart — 50 steps is long enough for the whole atmosphere to load up.
var _gate: int = SAMPLE_EVERY - 1
var _in_pair: int = 0             # 0 = not sampling, 1 = first of the pair, 2 = second

# Per-sampled-step accumulation. `_prev_*` hold the previous checkpoint's totals; the legs are the differences.
var _water_back: bool = false
var _moisture_back: bool = false
var _soil_back: bool = false
var _prev_open: float = 0.0
var _prev_all: float = 0.0
var _open_start: float = 0.0
var _all_start: float = 0.0
var _legs_open: Dictionary = {}
var _legs_all: Dictionary = {}
var _parts_open: Dictionary = {}  # closing per-channel split, for reading the shape of the loss
var _parts_all: Dictionary = {}
# Closing totals of the FIRST sample of a pair, so the second can report `chain`.
var _pair_open_end: float = NAN
var _pair_all_end: float = NAN


func setup(field) -> void:
	_f = field


## Called once per field step by LAMaterialFieldSphereStep3D, BEFORE _gpu.step(). Arms the driver's between-pass
## probe on the steps this sampler wants and leaves it disarmed otherwise, so the normal one-submit step path is
## what runs on every other step.
func pre_step() -> void:
	if _f == null or _f._gpu == null or not _f._gpu.has_method("set_step_probe"):
		return
	if _in_pair == 1:
		_in_pair = 2                       # second half of the pair — sample again, immediately after the first
	else:
		_gate += 1
		if _gate >= SAMPLE_EVERY:
			_gate = 0
			_in_pair = 1
			_pair_open_end = NAN
			_pair_all_end = NAN
		else:
			_in_pair = 0
	if _in_pair == 0:
		_f._gpu.set_step_probe(Callable())
		return
	_f._gpu.set_step_probe(Callable(self, "on_checkpoint"))


## The between-pass probe. `pass_index` -1 = before any pass ran; otherwise the index of the pass that just
## finished, with `pass_name` its script basename.
func on_checkpoint(pass_index: int, pass_name: String) -> void:
	if pass_index < 0:
		_water_back = false
		_moisture_back = false
		_soil_back = false
		_legs_open = {}
		_legs_all = {}
		var opening: Array = _totals()
		_open_start = opening[0]
		_all_start = opening[1]
		_prev_open = _open_start
		_prev_all = _all_start
		return
	# The producer's OUTPUT is what a checkpoint taken after it must read, so the half flips here, not before.
	if pass_name == WATER_PRODUCER:
		_water_back = true
	if pass_name == MOISTURE_PRODUCER:
		_moisture_back = true
	if pass_name == SOIL_PRODUCER:
		_soil_back = true
	var now: Array = _totals()
	var key: String = _leg_key(pass_name)
	_legs_open[key] = snappedf(now[0] - _prev_open, 0.0001)
	_legs_all[key] = snappedf(now[1] - _prev_all, 0.0001)
	_prev_open = now[0]
	_prev_all = now[1]
	_parts_open = now[2]
	_parts_all = now[3]


## Called once per field step by LAMaterialFieldSphereStep3D, AFTER _gpu.step(). Prints the sampled step's
## budget; a no-op on unsampled steps.
func post_step() -> void:
	if _in_pair == 0 or _legs_open.is_empty():
		return
	var step_open: float = _prev_open - _open_start
	var step_all: float = _prev_all - _all_start
	var legs_open_sum: float = 0.0
	var legs_all_sum: float = 0.0
	for k in _legs_open:
		legs_open_sum += float(_legs_open[k])
		legs_all_sum += float(_legs_all[k])
	var out: Dictionary = {
		"field_step": _step_index(),
		"pair": _in_pair,
		"open_total": snappedf(_prev_open, 0.01),
		"all_total": snappedf(_prev_all, 0.01),
		"buried": snappedf(_prev_all - _prev_open, 0.01),
		"open_parts": _parts_open,
		"all_parts": _parts_all,
		"step_open": snappedf(step_open, 0.0001),
		"step_all": snappedf(step_all, 0.0001),
		"residual_open": snappedf(step_open - legs_open_sum, 0.0001),
		"residual_all": snappedf(step_all - legs_all_sum, 0.0001),
		"legs_open": _legs_open,
		"legs_all": _legs_all,
	}
	if _in_pair == 2 and not is_nan(_pair_open_end):
		# The instrument's only falsifiable number: this step opened where the previous one closed, or the
		# half-mapping / parity flip in the header is wrong.
		out["chain_open"] = snappedf(_open_start - _pair_open_end, 0.0001)
		out["chain_all"] = snappedf(_all_start - _pair_all_end, 0.0001)
	_pair_open_end = _prev_open
	_pair_all_end = _prev_all
	print("H2O_BUDGET=", JSON.stringify(out))
	_legs_open = {}
	_legs_all = {}


# --- internals ----------------------------------------------------------------

## The four H₂O channels at the half that is current RIGHT NOW, summed twice: over the ledger's masks (`open`)
## and mask-free (`all`). Returns [open_total, all_total, open_parts, all_parts].
func _totals() -> Array:
	var gpu = _f._gpu
	var cc: int = _f._cell_count
	var solid: PackedFloat32Array = gpu.read_raw("solid", 0)
	var phase: int = gpu.probe_phase()
	var back: int = 1 - phase
	var water: PackedFloat32Array = gpu.read_raw("water", back if _water_back else phase)
	var moisture: PackedFloat32Array = gpu.read_raw("moisture", back if _moisture_back else phase)
	var soil: PackedFloat32Array = gpu.read_raw("soil", back if _soil_back else phase)
	var snow: PackedFloat32Array = gpu.read_raw("snow", 0)
	var regolith: PackedByteArray = _f._regolith
	var has_reg: bool = regolith.size() == cc
	var has_solid: bool = solid.size() >= cc

	var solid_cells: int = 0
	var w_open: float = 0.0
	var w_all: float = 0.0
	var m_open: float = 0.0
	var m_all: float = 0.0
	var s_open: float = 0.0
	var s_all: float = 0.0
	var g_open: float = 0.0
	var g_all: float = 0.0
	var n: int = cc
	if water.size() < n or moisture.size() < n or soil.size() < n or snow.size() < n:
		return [0.0, 0.0, {}, {}]
	for c in n:
		var is_open: bool = (not has_solid) or solid[c] == 0.0
		var wv: float = water[c]
		var mv: float = moisture[c]
		var sv: float = snow[c]
		var gv: float = soil[c]
		w_all += wv
		m_all += mv
		s_all += sv
		g_all += gv
		if is_open:
			w_open += wv
			m_open += mv
			s_open += sv
		else:
			solid_cells += 1
		if (not has_reg) or regolith[c] != 0:
			g_open += gv
	var open_total: float = w_open + m_open + s_open + g_open
	var all_total: float = w_all + m_all + s_all + g_all
	var open_parts: Dictionary = {
		"water": snappedf(w_open, 0.01), "moisture": snappedf(m_open, 0.01),
		"snow": snappedf(s_open, 0.01), "soil": snappedf(g_open, 0.01)}
	var all_parts: Dictionary = {
		"water": snappedf(w_all, 0.01), "moisture": snappedf(m_all, 0.01),
		"snow": snappedf(s_all, 0.01), "soil": snappedf(g_all, 0.01),
		"solid_cells": solid_cells}
	return [open_total, all_total, open_parts, all_parts]


## Short leg label: "WaterSlumpLavaPass" -> "water_slump_lava" (mirrors the driver's GPU-timing gauge keys).
func _leg_key(pass_name: String) -> String:
	var s: String = pass_name
	if s.ends_with("Pass"):
		s = s.substr(0, s.length() - 4)
	return s.to_snake_case()


func _step_index() -> int:
	var gpu = _f._gpu
	return int(gpu._step_index) if gpu != null else -1
