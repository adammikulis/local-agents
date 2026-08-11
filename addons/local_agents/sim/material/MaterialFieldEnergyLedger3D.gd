class_name LAMaterialFieldEnergyLedger3D
extends RefCounted

## ~11 W/m² of a ~150 W/m² gap, and it WARMED 15 °C → 30 °C over a run the radiative books say should have
## cooled 47 °C. About 140 W/m² enters from terms nothing books. This is the gauge that can see them.
##   energy_stock = Σ over EVERY cell, rock and void, of  rc(cell) * cell_volume_m3(cell) * (T + 273.15)   [joules]
##     `energy_emitted` (its :294-321), which are sums of per-cell fluxes in W/m², so a face area of
## capacity by carrier and the water leg falls from 5.5171e13 to 1.852e13 J/K — 66.4%, and to three figures
## (1.708e10 J/K each) leaving the `water` channel for `soil`, which carries no capacity: 2146 * 4.171e6 *
## — 51764 W/m², against 240 W/m² of longwave. Two unbooked sinks exist only in that arm and this gauge cannot

## Samples to discard before latching the run-long BASELINE. The drain probe lands one drain after it is
## armed, so the FIRST sample reads a possibly-stale rock_fill mirror; and the report path can fire before the
## field has stepped at all, which would book world-gen's settling as drift. `energy_first_step` publishes
const BASELINE_SKIP_SAMPLES: int = 2

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
	# A GAUGE THAT CANNOT SEE ALL ITS LEGS MUST SAY SO, NOT PUBLISH A SMALLER NUMBER.
	#
	# `rc` is built from channel MIRRORS, and a demand-gated channel is only refreshed when something called
	# request_channel — so which legs are present depends on which CONSUMERS are alive. An absent leg
	# contributed zero capacity and the stock silently shrank: measured 2026-08-11 by
	# scripts/check_observer_independence.sh, `energy_stock` differed by 87.13% between a run with the
	# presentation layer and the same run with --bare. That is the gauge reading the observer, not the planet.
	#
	# Reporting "unmeasured" is the honest answer and it is what the element inventory already does with
	# `mass_live`. A wrong number is worse than an absent one, because only the absent one stops a reader.
	var missing: PackedStringArray = PackedStringArray()
	for leg_name in cap_live:
		if not bool(cap_live[leg_name]):
			missing.append(String(leg_name))
	if missing.size() > 0:
		out["energy_stock"] = null
		out["energy_stock_live"] = cap_live
		out["energy_stock_missing"] = missing
		out["energy_stock_cells"] = cc
		LASimReport.gauge("energy_stock_ms", float(Time.get_ticks_usec() - t0) / 1000.0)
		return out
	# ENERGY IS rc * V * T, AND V IS PER CELL AND IN CUBIC METRES. Both halves of that were wrong here.
	# `volume = cell_size^3` used one uniform volume for every cell on a grid whose cells differ by up to
	# 8.8x, AND it was in model units cubed while rc is J/m^3/K, so a figure the header calls "[joules]" was
	# short by METRES_PER_MODEL_UNIT^3, about 4.8e6. The two errors do not cancel each other and they do not
	# cancel against the booked fluxes below, which carried the squared version of the same mistake.
	var grid = _f._sphere
	var have_grid: bool = grid != null and grid.cell_count == cc
	var uniform_m3: float = pow(cell_size * LAPhysical.METRES_PER_MODEL_UNIT, 3.0)
	var stock: float = 0.0
	var d_heat_j: float = 0.0
	var d_cap_j: float = 0.0
	var vol_total_m3: float = 0.0
	for c in cc:
		var rc: float = rc_all[c]
		if solid[c] != 0 and c % depth == 0:
			shell_solid += 1
		var tk: float = temp[c] + LAPhysical.KELVIN_OFFSET
		var v_m3: float = LAFieldTotals.cell_volume_m3(grid, c) if have_grid else uniform_m3
		vol_total_m3 += v_m3
		rc_sum_t += rc * tk
		stock += rc * tk * v_m3
		if have_prev:
			d_heat += _prev_rc[c] * (tk - _prev_tk[c])
			d_cap += (rc - _prev_rc[c]) * tk
			d_heat_j += _prev_rc[c] * (tk - _prev_tk[c]) * v_m3
			d_cap_j += (rc - _prev_rc[c]) * tk * v_m3
		_prev_rc[c] = rc
		_prev_tk[c] = tk

	var cap_raw: Dictionary = LAHeatCapacity.legs(ch, cc)
	var cap_legs: Dictionary = {}
	# The per-leg capacities are sums over cells of rc, so they take the MEAN cell volume — the split between
	# legs is what they are for, and a per-cell split would mean re-walking the field once per leg.
	var mean_m3: float = (vol_total_m3 / float(cc)) if cc > 0 else 0.0
	for k in cap_raw:
		cap_legs[k] = snappedf(float(cap_raw[k]) * mean_m3, 1.0)
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

	# THE BOOKED RATES, in watts. LAMaterialFieldEnergyBudget3D now sums each cell's flux against that cell's
	# OWN outward face area in m², so these arrive as watts and need no conversion here. They used to be
	# W/m² sums multiplied by one uniform `cell_size²` — uniform on a grid whose faces vary as r², and in
	# model units against a flux in W/m², so short by METRES_PER_MODEL_UNIT² (~2.8e4). The stock above
	# carried the CUBED version of the same mistake, so the two did not cancel: the residual-over-booked
	# ratio inherited the difference, a factor of METRES_PER_MODEL_UNIT.
	var solar_w: float = float(flux.get("energy_absorbed_w", 0.0))
	var lw_w: float = float(flux.get("energy_emitted_w", 0.0))
	var geo_flux: float = 0.0
	if _f._geotherm != null:
		geo_flux = float(_f._geotherm.report().get("core_flux_w_m2", 0.0))
	# The geotherm's scalar flux crosses the INNERMOST solid faces (see the header), whose area is the r == 0
	# inward face, not a cube side.
	var core_face_m2: float = 0.0
	if have_grid:
		var k2: float = LAPhysical.METRES_PER_MODEL_UNIT * LAPhysical.METRES_PER_MODEL_UNIT
		for s_col in int(cc / depth):
			core_face_m2 += grid.face_area_inward(s_col * depth) * k2
		core_face_m2 = core_face_m2 / float(maxi(int(cc / depth), 1))
	else:
		core_face_m2 = pow(cell_size * LAPhysical.METRES_PER_MODEL_UNIT, 2.0)
	var geo_w: float = geo_flux * core_face_m2 * float(shell_solid)
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
	if _first_step < 0 and _sealed() and have_prev:
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

	# (262.3) and against the ~140 W/m² this planet gains from terms nothing books. The denominator is the
	# The REAL radiating area of the cells the budget counted, summed there against each cell's own outward
	# face. It was `ref_cells * cell_size²` — one uniform cube side, in model units, for faces that vary as r².
	var area: float = float(flux.get("energy_face_area_m2", 0.0))
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


## True once LAMaterialFieldSeal3D has closed the books. Before it, this module publishes totals but latches
## no baseline and reports no run-drift — because until the world is sealed the only thing a drift gauge can
## measure is the planet being assembled.
func _sealed() -> bool:
	return _f != null and _f._seal != null and _f._seal.sealed()


func _note_seed(key: String, value: float) -> void:
	if _f != null and _f._seal != null:
		_f._seal.note_seed({key: value})
