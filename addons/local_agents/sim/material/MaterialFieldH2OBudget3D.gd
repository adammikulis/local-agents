class_name LAMaterialFieldH2OBudget3D
extends RefCounted

const CellVolScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldCellVolume3D.gd")

## LAMaterialFieldH2OBudget3D: a PER-PASS mass budget for the whole conserved H₂O ledger, so a water drain has

## Field steps between sampled PAIRS. Every 50 puts a line either side of the horizons the dynamic-sea water
const SAMPLE_EVERY: int = 50

## Pass names (LAMaterialSphereGPU3D._pass_names = the script basename) at which each pair channel's current
## half switches from live to back. Matched by name, not index: see the header.

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
	var producers: Dictionary = LAFieldAttributionRecords.PRODUCERS
	if pass_name == String(producers.get("water", "")):
		_water_back = true
	if pass_name == String(producers.get("moisture", "")):
		_moisture_back = true
	if pass_name == String(producers.get("soil", "")):
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
	var vol: PackedFloat32Array = CellVolScript.of(_f)
	if vol.size() != n:
		return [0.0, 0.0, {}, {}]
	for c in n:
		var is_open: bool = (not has_solid) or solid[c] == 0.0
		var w: float = vol[c]
		var wv: float = water[c] * w
		var mv: float = moisture[c] * w
		var sv: float = snow[c] * w
		var gv: float = soil[c] * w
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
