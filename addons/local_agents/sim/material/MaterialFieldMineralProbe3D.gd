class_name LAMaterialFieldMineralProbe3D
extends RefCounted

## LAMaterialFieldMineralProbe3D: a PER-PASS mass budget for the whole conserved MINERAL ledger, so a rock leak


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

# The CPU injection queue flushes once per FRAME, outside the per-step loop this probe brackets, so its edits
# land in NO leg. These carry its cumulative books so each line can report what it moved since the last one.
var _prev_inj_moved: float = 0.0
var _prev_inj_minted: float = 0.0


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
	var inj_moved: float = 0.0
	var inj_minted: float = 0.0
	if _f._inject != null and _f._inject.queue != null:
		inj_moved = float(_f._inject.queue.mineral_moved)
		inj_minted = float(_f._inject.queue.mineral_minted)
	out["inject_moved"] = snappedf(inj_moved - _prev_inj_moved, 0.0001)
	out["inject_minted"] = snappedf(inj_minted - _prev_inj_minted, 0.0001)
	_prev_inj_moved = inj_moved
	_prev_inj_minted = inj_minted
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
	# VOLUME-WEIGHTED, IN CUBIC METRES — this probe's whole job is to say WHICH PASS gained or lost mineral,
	# and a pass that only MOVES rock between cells of different size shows up as a gain or a loss in a flat
	# sum. That makes the per-pass attribution point at the wrong pass, which is worse than no attribution.
	var grid = _f._sphere
	var have_grid: bool = grid != null and grid.cell_count == cc
	for c in cc:
		var is_open: bool = (not has_solid) or solid[c] == 0.0
		var vol: float = LAFieldTotals.cell_volume_m3(grid, c) if have_grid else 1.0
		var rv: float = rock[c] * vol
		var lv: float = lava[c] * vol
		var sv: float = sed[c] * vol
		var uv: float = susp[c] * vol
		var dv: float = dust[c] * vol
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
