class_name LAMaterialFieldEnergyLedger3D
extends RefCounted

const CellVolScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldCellVolume3D.gd")

## energy_stock = Σ over every cell, rock and void, of rc(cell) * cell_volume * (T + 273.15), in joules.

const LEGS: PackedStringArray = ["rock_fill", "lava", "fuel", "dust", "detritus", "fungus",
	"carbonate", "silica"]

var _f = null                                # back-reference to the owning LAMaterialField3D

# Previous sample's per-cell capacity and ABSOLUTE temperature, for the exact ΔU = Σrc₀ΔT + ΣΔrc·T₁ split.
var _prev_rc: PackedFloat32Array = PackedFloat32Array()
var _prev_tk: PackedFloat32Array = PackedFloat32Array()
var _prev_stock: float = NAN
var _prev_step: int = -1

# Run-long baseline and the books accumulated against it. Everything here is zeroed at the sample the
# baseline is latched, so the cumulative terms and the stock change span exactly the same window.
var _first_stock: float = NAN
var _first_step: int = -1
var _first_inject_j: float = 0.0
var _first_unsourced_dc: float = 0.0
var _samples: int = 0
var _cum_heat: float = 0.0
var _cum_cap: float = 0.0
var _cum_solar: float = 0.0
var _cum_lw: float = 0.0
var _cum_geo: float = 0.0
# The grid's TOTAL heat capacity at the baseline, split by which substance carries it (J/K). A scalar
# `energy_capacity_*` says the capacity moved and cannot say WHICH RESERVOIR moved, which is the difference
# between "the planet is losing water" and "bedrock is crossing the solidity threshold" — opposite diagnoses.
var _first_cap: Dictionary = {}


func setup(field) -> void:
	_f = field


func report(step_index: int, flux: Dictionary) -> Dictionary:
	var out: Dictionary = _blank()
	if _f == null or _f._cell_count <= 0 or _f._dim_y <= 0:
		return out
	var t0: int = Time.get_ticks_usec()
	var cc: int = _f._cell_count
	var solid: PackedByteArray = _f._solid
	var temp: PackedFloat32Array = _f._temp
	if solid.size() != cc or temp.size() != cc:
		return out
	var cell_size: float = float(_f._cell_size)
	if cell_size <= 0.0:
		return out

	# THE ONE DEMAND-GATED LEG, READ-ONLY. Collect the probe the previous sample armed, then arm the next.
	var legs: Dictionary = {}
	if _f._gpu != null and _f._gpu.has_method("take_probe"):
		legs = _f._gpu.take_probe()
		_f._gpu.request_probe(LEGS)
	var probe_rock: bool = legs.has("rock_fill")
	var rock_fill: PackedFloat32Array = legs.get("rock_fill", _f._rock_fill)
	var lava: PackedFloat32Array = legs.get("lava", _f._lava)
	var fuel: PackedFloat32Array = legs.get("fuel", _f._fuel)
	var water: PackedFloat32Array = _f._water
	var snow: PackedFloat32Array = _f._snow
	# biomass and detritus are NOT demand-gated (MaterialSphereGPU3D.SINGLE_CHANNELS, always mirrored), so
	# they need no probe leg. lava and fuel are, hence their presence in LEGS above.
	var biomass: PackedFloat32Array = _f._biomass
	var detritus: PackedFloat32Array = _f._detritus
	var has_rock: bool = probe_rock and rock_fill.size() == cc
	var has_lava: bool = legs.has("lava") and lava.size() == cc
	var has_fuel: bool = legs.has("fuel") and fuel.size() == cc
	var has_water: bool = water.size() == cc
	var has_snow: bool = snow.size() == cc
	var has_org: bool = biomass.size() == cc and detritus.size() == cc

	var depth: int = _f._dim_y
	var have_prev: bool = _prev_rc.size() == cc and _prev_tk.size() == cc
	if not have_prev:
		_prev_rc.resize(cc)
		_prev_tk.resize(cc)
	var rc_sum_t: float = 0.0        # Σ rc*T_K, in J per m³ of cell — scaled by the cell volume below
	var d_heat: float = 0.0          # Σ rc₀ΔT
	var d_cap: float = 0.0           # Σ Δrc·T₁
	var shell_solid: int = 0         # solid cells on the r == 0 face — the geotherm's own population
	var ch: Dictionary = {
		"rock_fill": rock_fill if has_rock else PackedFloat32Array(),
		"lava": lava if has_lava else PackedFloat32Array(),
		"fuel": fuel if has_fuel else PackedFloat32Array(),
		"water": water if has_water else PackedFloat32Array(),
		"snow": snow if has_snow else PackedFloat32Array(),
		"biomass": biomass if has_org else PackedFloat32Array(),
		"detritus": detritus if has_org else PackedFloat32Array(),
		# Not demand-gated, so the always-hot CPU mirror is the honest source.
		"sediment": _f._sediment, "susp": _f._susp, "soil": _f._soil, "moisture": _f._moisture,
		"porosity": _f._porosity,
		# Demand-gated or mirror-less: probe legs only. `.get(name, empty)` rather than a mirror fallback,
		# so a leg that did not arrive reads as ABSENT (contributing zero, and reported so in
		# `energy_stock_live`) instead of as a stale value pretending to be a measurement.
		"dust": legs.get("dust", PackedFloat32Array()),
		"fungus": legs.get("fungus", PackedFloat32Array()),
		"carbonate": legs.get("carbonate", PackedFloat32Array()),
		"silica": legs.get("silica", PackedFloat32Array()),
	}
	var rc_all: PackedFloat64Array = LAHeatCapacity.field(ch, cc)
	var cap_live: Dictionary = LAHeatCapacity.live_map(ch, cc)
	# Each cell carries its OWN volume: rc is J/m3K, so the stock is rc*T*volume summed cell by cell.
	var vol: PackedFloat32Array = CellVolScript.of(_f)
	if vol.size() != cc:
		return out
	for c in cc:
		var rc: float = rc_all[c]
		if solid[c] != 0 and c % depth == 0:
			shell_solid += 1
		var tk: float = temp[c] + LAPhysical.KELVIN_OFFSET
		var w: float = vol[c]
		rc_sum_t += rc * tk * w
		if have_prev:
			d_heat += _prev_rc[c] * (tk - _prev_tk[c]) * w
			d_cap += (rc - _prev_rc[c]) * tk * w
		_prev_rc[c] = rc
		_prev_tk[c] = tk

	var stock: float = rc_sum_t
	var d_heat_j: float = d_heat
	var d_cap_j: float = d_cap
	var cap_raw: Dictionary = LAHeatCapacity.legs(ch, cc, vol)
	var cap_legs: Dictionary = {}
	for k in cap_raw:
		cap_legs[k] = snappedf(float(cap_raw[k]), 1.0)
	out["energy_stock"] = stock
	out["energy_stock_cells"] = cc
	# Every channel the capacity mix reads, and whether it actually arrived. Built by LAHeatCapacity from the
	# same dictionary the mix consumed, so it cannot fall out of step with the model the way a hand-written
	# list of six flags did while the model was counting fifteen channels.
	out["energy_stock_live"] = cap_live
	# The grid's total heat capacity, in J/K, and which substance holds it. `energy_capacity_w_m2` is the RATE
	# this moves at; these say what moved.
	var cap_total: float = 0.0
	for k in cap_legs:
		cap_total += float(cap_legs[k])
	out["energy_cap_j_k"] = cap_total
	out["energy_cap_legs"] = cap_legs

	# THE BOOKED RATES, in watts. `energy_absorbed` / `energy_emitted` are sums of per-cell fluxes in W/m², so
	# each cell's own face area (cell_size²) turns the sum into watts. The geotherm's scalar flux covers the
	# SOLID r == 0 face only (see the header).
	var face: float = cell_size * cell_size
	var solar_w: float = float(flux.get("energy_absorbed", 0.0)) * face
	var lw_w: float = float(flux.get("energy_emitted", 0.0)) * face
	var geo_flux: float = 0.0
	if _f._geotherm != null:
		geo_flux = float(_f._geotherm.report().get("core_flux_w_m2", 0.0))
	var geo_w: float = geo_flux * face * float(shell_solid)
	var inject_j: float = 0.0
	var unsourced_dc: float = 0.0
	if _f._inject != null and _f._inject.queue != null:
		inject_j = float(_f._inject.queue.heat_energy_j)
		unsourced_dc = float(_f._inject.queue.heat_unsourced_dc)

	# PER-SAMPLE DRIFT, per FIELD STEP.
	var steps: int = step_index - _prev_step
	var dt_real: float = LAMaterialFieldSphereStep3D.real_seconds_per_step()
	if steps > 0 and _prev_step >= 0 and not is_nan(_prev_stock):
		out["energy_drift"] = stock - _prev_stock
		out["energy_drift_per_step"] = (stock - _prev_stock) / float(steps)
		out["energy_drift_steps"] = steps
	if steps > 0 or _prev_step < 0:
		_prev_stock = stock
		_prev_step = step_index

	# RUN-LONG BOOKS. The baseline zeroes every cumulative term, so the stock change and the booked terms span
	# exactly the same window; accumulation starts at the sample AFTER the latch.
	_samples += 1
	var latched: bool = false
	if _first_step < 0 and _at_seal(step_index):
		_first_stock = stock
		_note_seed("energy_j", stock)
		_first_step = step_index
		_first_inject_j = inject_j
		_first_unsourced_dc = unsourced_dc
		_cum_heat = 0.0
		_cum_cap = 0.0
		_cum_solar = 0.0
		_cum_lw = 0.0
		_cum_geo = 0.0
		_first_cap = cap_legs
		latched = true
	if _first_step >= 0 and not latched and steps > 0:
		# Rectangle rule over the window, at the flux sampled at its right-hand end — the same approximation
		# LAMaterialFieldEnergyBudget3D's own running totals make, integrated against the REAL seconds the
		# kernel applies (`dt_s`), not the simulated ones.
		var window_s: float = dt_real * float(steps)
		_cum_heat += d_heat_j
		_cum_cap += d_cap_j
		_cum_solar += solar_w * window_s
		_cum_lw += lw_w * window_s
		_cum_geo += geo_w * window_s
	var run_steps: int = step_index - _first_step if _first_step >= 0 else 0
	out["energy_run_steps"] = run_steps
	out["energy_stock_samples"] = _samples
	out["energy_first_step"] = _first_step
	out["energy_stock_first"] = _first_stock if not is_nan(_first_stock) else 0.0
	out["energy_cap_legs_first"] = _first_cap
	if run_steps <= 0 or is_nan(_first_stock):
		out["energy_stock_scan_ms"] = snappedf(float(Time.get_ticks_usec() - t0) / 1000.0, 0.01)
		return out

	var run_drift: float = stock - _first_stock
	var cum_inject: float = inject_j - _first_inject_j
	var booked: float = _cum_solar - _cum_lw + _cum_geo + cum_inject
	out["energy_run_drift"] = run_drift
	out["energy_run_drift_per_step"] = run_drift / float(run_steps)
	out["energy_booked"] = booked
	out["energy_residual"] = run_drift - booked
	# THE DECOMPOSITION'S OWN CHECK. Σrc₀ΔT + ΣΔrc·T₁ is the stock change identically, so this is ~0 or the
	# split is wrong — the one number here that is allowed to be a tautology, because it is testing arithmetic
	# rather than physics.
	out["energy_split_close"] = (_cum_heat + _cum_cap) - run_drift

	var ref_cells: int = int(flux.get("energy_cells", 0))
	var area: float = float(ref_cells) * face
	out["energy_ref_area_m2"] = area
	if area > 0.0:
		var run_s: float = dt_real * float(run_steps)
		if run_s > 0.0:
			var inv: float = 1.0 / (area * run_s)
			out["energy_drift_w_m2"] = run_drift * inv
			out["energy_heat_w_m2"] = _cum_heat * inv
			out["energy_capacity_w_m2"] = _cum_cap * inv
			out["energy_booked_w_m2"] = booked * inv
			out["energy_residual_w_m2"] = (run_drift - booked) * inv
			out["energy_book_solar_w_m2"] = _cum_solar * inv
			out["energy_book_lw_w_m2"] = _cum_lw * inv
			out["energy_book_geo_w_m2"] = _cum_geo * inv
			out["energy_book_inject_w_m2"] = cum_inject * inv
	# The one injection form that names no store it came out of. Degrees x cells, unconverted — see the
	# header's unbooked list, item 7.
	out["energy_unsourced_dc"] = unsourced_dc - _first_unsourced_dc
	out["energy_geo_shell_cells"] = shell_solid
	out["energy_stock_scan_ms"] = snappedf(float(Time.get_ticks_usec() - t0) / 1000.0, 0.01)
	return out


func _blank() -> Dictionary:
	return {
		"energy_stock": 0.0, "energy_stock_first": 0.0, "energy_stock_cells": 0,
		"energy_drift": 0.0, "energy_drift_per_step": 0.0, "energy_drift_steps": 0,
		"energy_run_drift": 0.0, "energy_run_drift_per_step": 0.0, "energy_run_steps": 0,
		"energy_booked": 0.0, "energy_residual": 0.0, "energy_split_close": 0.0,
		"energy_drift_w_m2": 0.0, "energy_heat_w_m2": 0.0, "energy_capacity_w_m2": 0.0,
		"energy_booked_w_m2": 0.0, "energy_residual_w_m2": 0.0,
		"energy_book_solar_w_m2": 0.0, "energy_book_lw_w_m2": 0.0,
		"energy_book_geo_w_m2": 0.0, "energy_book_inject_w_m2": 0.0,
		"energy_unsourced_dc": 0.0, "energy_geo_shell_cells": 0, "energy_ref_area_m2": 0.0,
		"energy_stock_samples": 0, "energy_first_step": -1,
		"energy_cap_j_k": 0.0, "energy_cap_legs": {}, "energy_cap_legs_first": {},
		"energy_stock_scan_ms": 0.0, "energy_stock_live": {},
	}


## True only on the step LAMaterialFieldSeal3D latched the books. The seal drives one sample there; a sample
## on any other step cannot take a baseline, so a late one is impossible rather than merely unlikely.
func _at_seal(step_index: int) -> bool:
	return _f != null and _f._seal != null and step_index == _f._seal.baseline_step()


func _note_seed(key: String, value: float) -> void:
	if _f != null and _f._seal != null:
		_f._seal.note_seed({key: value})
