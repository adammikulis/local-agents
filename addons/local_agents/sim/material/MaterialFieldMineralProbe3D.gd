class_name LAMaterialFieldMineralProbe3D
extends RefCounted

## LAMaterialFieldMineralProbe3D: a PER-PASS mass budget for the whole conserved MINERAL ledger, so a rock leak
## or a rock mint has to NAME THE PASS that causes it instead of being argued about. Diagnostic only — created
## by LAMaterialFieldSphereStep3D and only when `LA_MINERAL_BUDGET` is in the environment, because a sampled
## step costs one CPU↔GPU round-trip per pass plus six full-grid readbacks.
##
## Direct sibling of LAMaterialFieldH2OBudget3D; read that file's header for why per-pass rather than per-kernel
## probe slots. The short version: each leg here is a DIFFERENCE OF MEASURED BUFFER STATE read straight off the
## device between two passes, so the legs sum to the step's total change BY CONSTRUCTION, no kernel's
## arithmetic is restated in GDScript, and a pass added tomorrow is instrumented for free.
##
## THE FIVE CHANNELS ARE ONE SUBSTANCE. bedrock `rock_fill` + molten `lava` + loose `sediment` + waterborne
## `susp` + airborne `dust`. Every transfer the substrate performs (M5 solidify, M6 melt, M3 settle, M4 loft,
## D1 weather, D2 lithify, erosion scour, slump, dust deposit) moves mineral BETWEEN these five, so a pass that
## is conserving shows `step_all` ≈ 0 however large its individual channel deltas are. A pass with a nonzero
## `d` in `legs_all` is creating or destroying rock, and its magnitude is the answer in units/step.
##
## TWO MASKS, AND THE DIFFERENCE BETWEEN THEM IS ITSELF A RESULT.
##   `all`  — all five channels over EVERY cell. THIS IS THE LEDGER (see LAMaterialFieldMineralBudget3D's
##            header for why mineral's inclusion rule is mask-free: `solid` is derived from `rock_fill`, so a
##            solidity mask would make the books a function of the quantity they measure).
##   `open` — the same five over open cells only, a memo line. A pass that leaves `all` flat while `open` falls
##            has BURIED rock, not destroyed it.
##
## WHICH HALF IS CURRENT. Four of the five channels are ping-pong PAIRs and one (`rock_fill`) is a SINGLE
## buffer edited in place. Every pair is written once per step, live → back, by ONE producer pass, so the
## current half at a checkpoint is `live` before that pass and `back` after. Keyed by pass NAME so a reordering
## of PASS_SCRIPTS cannot silently invalidate it:
##   lava      — WaterSlumpLavaPass (lava_flow writes lava[back]; ReactionsPass then edits lava[back] in place)
##   sediment  — WaterSlumpLavaPass (slump writes sediment[back]; Reactions + FireDust deposit into it after)
##   susp      — ErosionPickupPass  (fully writes susp[back] = susp[live] + scour)
##   dust      — FireDustPass       (dust_transport writes dust[back]; Reactions' M4 loft deliberately credits
##                                   dust[LIVE] BEFORE it, so the transport advects the lofted dust same-step)
##   rock_fill — SINGLE, no halves (ErosionPickup scours it, Reactions' M5/M6 trade it with lava)
##
## THE SELF-CHECK. `residual` is zero by construction (telescoping differences), which is worth nothing on its
## own, so the instrument samples steps in CONSECUTIVE PAIRS: `chain_all` is the second sample's opening total
## minus the first sample's closing total. If the half-mapping above were wrong, the opening read would land on
## a stale buffer and `chain_all` would be large. It is the only number here that can falsify the instrument.
##
## MUTUALLY EXCLUSIVE WITH `LA_H2O_BUDGET`. Both arm the driver's single `set_step_probe` callable, so setting
## both would silently give one of them every checkpoint and the other none. LAMaterialFieldSphereStep3D warns
## and keeps only this one when both are present.
##
## WHAT IT MEASURED, 2026-08-03, seed 4242, `--planet-only --run-frames=300 --fast=8 --fixed-fps 60`, eight
## sampled pairs from field_step 1 to 359. **ELEVEN OF THE TWELVE PASSES CONSERVE MINERAL EXACTLY**
## (`legs_all` 0.0000 for solid_derive, water_slump_lava, lava_cell_list, thermal, gas_wind, atmosphere, soil,
## erosion_pickup, reactions, activity and eco_surface, at every sample). **The whole leak is `fire_dust`**,
## and it grows with the dust load: -0.0008/step at `dust` 1.85, -0.0023 at 4.49, -0.0349 at 9.68, -0.0516 at
## 26.68. That is the same quantity LAMaterialFieldMineralBudget3D sees as `mineral_net_per_step` -0.043 on a
## 600-frame run, where dust reaches ~210.
##
## The likely mechanism, NOT yet confirmed by a fix: FireDustPass is relevance-gated. A cell whose stride skips
## this step does `dust_out[g] = dust_in[g]` (dust_transport_sphere3d.glsl:83) and so never collects the
## downward/lateral flux its running neighbours already SENT, and the CFL scale (now inline in
## dust_transport_sphere3d.glsl, after dust_outscale_sphere3d.glsl was deleted) is 1.0 for
## a gated cell, which the transport's inflow terms read as "that neighbour sent nothing". Both directions drop
## mass on the floor. Anyone fixing it should re-run this probe and watch `fire_dust` go to 0.0000 — that is
## the acceptance test, and it is the reason a per-pass instrument was worth building instead of arguing.
##
## `chain_all` is 0.0 at every sampled pair except one (+1.60 at step 359), and that exception is the vent's
## injection queue flushing between the two steps of the pair — a real source, not an instrument error. So the
## half-mapping above is verified, not assumed.
## (Explicit types only, no ':=' inferred typing.)

## THE FIVE-LEG SUM IS NO LONGER EXACTLY CONSERVED THROUGH `ReactionsPass`, as of 2026-08-08, and a reader
## chasing a leak needs to know before they chase this one. The mineral phases carry real formulas now
## (silicate CaSiO3), and record D1b — the Urey reaction — converts silicate bedrock into carbonate and
## silica, which are two OTHER channels this probe does not sum. So `reactions` will show a small standing
## negative that is weathering working, not mass vanishing. It is tiny: 0.031 cell-units over a whole
## 600-frame run, against a five-leg total of 31978. Anything larger than that is a real leak. The strict
## gauge is `lith_element_Ca` / `lith_element_Si` in LAMaterialFieldMineralBudget3D.

## Field steps between sampled PAIRS. 2 of every 50 steps paying the round-trips is a cost the run does not
## notice, and it matches the H₂O probe's cadence so the two diagnostics line up on the same horizons.
const SAMPLE_EVERY: int = 50

const LAVA_PRODUCER: String = "WaterSlumpLavaPass"
const SEDIMENT_PRODUCER: String = "WaterSlumpLavaPass"
const SUSP_PRODUCER: String = "ErosionPickupPass"
const DUST_PRODUCER: String = "FireDustPass"

var _f = null                     # back-reference to the owning LAMaterialField3D
# Primed so the FIRST pair samples at field_step 1. The world's opening mineral total is the number that
# separates "this run gained rock" from "this build started with more rock", and sampling first at step 50
# cannot tell them apart.
var _gate: int = SAMPLE_EVERY - 1
var _in_pair: int = 0             # 0 = not sampling, 1 = first of the pair, 2 = second

var _lava_back: bool = false
var _sed_back: bool = false
var _susp_back: bool = false
var _dust_back: bool = false
var _prev_open: float = 0.0
var _prev_all: float = 0.0
var _open_start: float = 0.0
var _all_start: float = 0.0
var _legs_open: Dictionary = {}
var _legs_all: Dictionary = {}
var _parts_all: Dictionary = {}   # closing per-channel split, for reading the SHAPE of a gain/loss
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
		_lava_back = false
		_sed_back = false
		_susp_back = false
		_dust_back = false
		_legs_open = {}
		_legs_all = {}
		var opening: Array = _totals()
		_open_start = opening[0]
		_all_start = opening[1]
		_prev_open = _open_start
		_prev_all = _all_start
		return
	# The producer's OUTPUT is what a checkpoint taken after it must read, so the half flips here, not before.
	if pass_name == LAVA_PRODUCER:
		_lava_back = true
	if pass_name == SEDIMENT_PRODUCER:
		_sed_back = true
	if pass_name == SUSP_PRODUCER:
		_susp_back = true
	if pass_name == DUST_PRODUCER:
		_dust_back = true
	var now: Array = _totals()
	var key: String = _leg_key(pass_name)
	_legs_open[key] = snappedf(now[0] - _prev_open, 0.0001)
	_legs_all[key] = snappedf(now[1] - _prev_all, 0.0001)
	_prev_open = now[0]
	_prev_all = now[1]
	_parts_all = now[2]


## Called once per field step by LAMaterialFieldSphereStep3D, AFTER _gpu.step(). Prints the sampled step's
## budget; a no-op on unsampled steps.
func post_step() -> void:
	if _in_pair == 0 or _legs_all.is_empty():
		return
	var step_open: float = _prev_open - _open_start
	var step_all: float = _prev_all - _all_start
	var legs_open_sum: float = 0.0
	var legs_all_sum: float = 0.0
	for k in _legs_all:
		legs_open_sum += float(_legs_open[k])
		legs_all_sum += float(_legs_all[k])
	var out: Dictionary = {
		"field_step": _step_index(),
		"pair": _in_pair,
		"open_total": snappedf(_prev_open, 0.01),
		"all_total": snappedf(_prev_all, 0.01),
		"buried": snappedf(_prev_all - _prev_open, 0.01),
		"all_parts": _parts_all,
		"step_open": snappedf(step_open, 0.0001),
		"step_all": snappedf(step_all, 0.0001),
		"residual_all": snappedf(step_all - legs_all_sum, 0.0001),
		"legs_open": _legs_open,
		"legs_all": _legs_all,
	}
	if _in_pair == 2 and not is_nan(_pair_all_end):
		# The instrument's only falsifiable number: this step opened where the previous one closed, or the
		# half-mapping / parity flip in the header is wrong.
		out["chain_open"] = snappedf(_open_start - _pair_open_end, 0.0001)
		out["chain_all"] = snappedf(_all_start - _pair_all_end, 0.0001)
	_pair_open_end = _prev_open
	_pair_all_end = _prev_all
	print("MINERAL_BUDGET=", JSON.stringify(out))
	_legs_open = {}
	_legs_all = {}


# --- internals ----------------------------------------------------------------

## The five mineral channels at the half that is current RIGHT NOW, summed twice: mask-free (`all`, the ledger)
## and over open cells (`open`, the burial memo). Returns [open_total, all_total, all_parts].
func _totals() -> Array:
	var gpu = _f._gpu
	var cc: int = _f._cell_count
	var solid: PackedFloat32Array = gpu.read_raw("solid", 0)
	var phase: int = gpu.probe_phase()
	var back: int = 1 - phase
	var rock: PackedFloat32Array = gpu.read_raw("rock_fill", 0)
	var lava: PackedFloat32Array = gpu.read_raw("lava", back if _lava_back else phase)
	var sed: PackedFloat32Array = gpu.read_raw("sediment", back if _sed_back else phase)
	var susp: PackedFloat32Array = gpu.read_raw("susp", back if _susp_back else phase)
	var dust: PackedFloat32Array = gpu.read_raw("dust", back if _dust_back else phase)
	var has_solid: bool = solid.size() >= cc
	if rock.size() < cc or lava.size() < cc or sed.size() < cc or susp.size() < cc or dust.size() < cc:
		return [0.0, 0.0, {}]

	var r_all: float = 0.0
	var r_open: float = 0.0
	var l_all: float = 0.0
	var l_open: float = 0.0
	var s_all: float = 0.0
	var s_open: float = 0.0
	var u_all: float = 0.0
	var u_open: float = 0.0
	var d_all: float = 0.0
	var d_open: float = 0.0
	var solid_cells: int = 0
	for c in cc:
		var is_open: bool = (not has_solid) or solid[c] == 0.0
		var rv: float = rock[c]
		var lv: float = lava[c]
		var sv: float = sed[c]
		var uv: float = susp[c]
		var dv: float = dust[c]
		r_all += rv
		l_all += lv
		s_all += sv
		u_all += uv
		d_all += dv
		if is_open:
			r_open += rv
			l_open += lv
			s_open += sv
			u_open += uv
			d_open += dv
		else:
			solid_cells += 1
	var open_total: float = r_open + l_open + s_open + u_open + d_open
	var all_total: float = r_all + l_all + s_all + u_all + d_all
	var all_parts: Dictionary = {
		"rock_fill": snappedf(r_all, 0.01), "lava": snappedf(l_all, 0.01),
		"sediment": snappedf(s_all, 0.01), "susp": snappedf(u_all, 0.01),
		"dust": snappedf(d_all, 0.01), "solid_cells": solid_cells}
	return [open_total, all_total, all_parts]


## Short leg label: "WaterSlumpLavaPass" -> "water_slump_lava" (mirrors the driver's GPU-timing gauge keys).
func _leg_key(pass_name: String) -> String:
	var s: String = pass_name
	if s.ends_with("Pass"):
		s = s.substr(0, s.length() - 4)
	return s.to_snake_case()


func _step_index() -> int:
	var gpu = _f._gpu
	return int(gpu._step_index) if gpu != null else -1
