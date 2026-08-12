class_name LAMaterialFieldMineralBudget3D
extends RefCounted

const CellVolScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldCellVolume3D.gd")


var _f = null                                # back-reference to the owning LAMaterialField3D

# Previous sample, for the per-sample drift. NAN until the first sample so the first reading reports no drift
# rather than a spurious one — the convention LAMaterialFieldLedger3D and LAMaterialFieldElementInventory3D share.
var _prev_total: float = NAN
var _prev_step: int = -1

# FIRST sample, and the run-long drift measured against it. The per-sample drift is one short window and so is
# a sample, not a trend: it catches whatever eruption happened to be venting. The run-long figure divides the
# WHOLE change by the WHOLE number of steps, which is the number to quote for "does this substance mint".
var _first_total: float = NAN
var _first_src: float = 0.0
var _first_step: int = -1
var _samples: int = 0

var _first_ca: float = NAN
var _first_si: float = NAN

# BASELINE BEDROCK, latched at the same sample the run-long drift baseline is, and the reference `crust_moved`
# measures displacement against. One extra full-grid float array (276 KB at the shipped resolution) and one
# extra accumulator inside the walk this module already does — no second scan.
var _rock_ref: PackedFloat32Array = PackedFloat32Array()
var _rock_ref_step: int = -1

const BASELINE_SKIP_SAMPLES: int = 2

const LEGS: PackedStringArray = ["rock_fill", "lava", "sediment", "susp", "dust", "carbonate", "silica"]

## The one declaration of what each mineral channel is made OF and how many moles a unit holds — the SAME
## table the load-time reaction gate checks every record against, so the instrument and the check cannot
## disagree. See LAMaterialFieldElementInventory3D for why this book is kept separate from the atmospheric one.
const BalanceScript: GDScript = preload("res://addons/local_agents/sim/material/reactions/ReactionBalance.gd")


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
	var legs: Dictionary = {}
	if _f._gpu != null and _f._gpu.has_method("take_probe"):
		legs = _f._gpu.take_probe()
		_f._gpu.request_probe(LEGS)
	var rock: PackedFloat32Array = legs.get("rock_fill", _f._rock_fill)
	var lava: PackedFloat32Array = legs.get("lava", _f._lava)
	var sed: PackedFloat32Array = legs.get("sediment", _f._sediment)
	var susp: PackedFloat32Array = legs.get("susp", _f._susp)
	var dust: PackedFloat32Array = legs.get("dust", _f._dust)
	# The two non-silicate species have NO CPU mirror on purpose — nothing on the CPU reads them, so there is
	# no `_f._carbonate` to fall back to and an absent probe leg reads as absent rather than as a stale zero.
	var carb: PackedFloat32Array = legs.get("carbonate", PackedFloat32Array())
	var silica: PackedFloat32Array = legs.get("silica", PackedFloat32Array())
	var has_carb: bool = carb.size() == cc
	var has_silica: bool = silica.size() == cc
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
	var carb_all: float = 0.0
	var carb_open: float = 0.0
	var silica_all: float = 0.0
	var silica_open: float = 0.0
	var carb_cells: int = 0
	var dusty_cells: int = 0
	var solid_cells: int = 0
	var crust_moved: float = 0.0
	var has_ref: bool = _rock_ref.size() == cc
	var vol: PackedFloat32Array = CellVolScript.of(_f)
	if vol.size() != cc:
		return out
	for c in cc:
		var is_open: bool = solid[c] == 0
		var w: float = vol[c]
		if not is_open:
			solid_cells += 1
		if has_rock:
			var v0: float = rock[c]
			rock_all += v0 * w
			if is_open:
				rock_open += v0 * w
			if has_ref:
				crust_moved += absf(v0 - _rock_ref[c]) * w
		if has_lava:
			var v1: float = lava[c]
			lava_all += v1 * w
			if is_open:
				lava_open += v1 * w
		if has_sed:
			var v2: float = sed[c]
			sed_all += v2 * w
			if is_open:
				sed_open += v2 * w
		if has_susp:
			var v3: float = susp[c]
			susp_all += v3 * w
			if is_open:
				susp_open += v3 * w
		if has_dust:
			var v4: float = dust[c]
			dust_all += v4 * w
			if is_open:
				dust_open += v4 * w
			if v4 > LAMaterialFieldQueries3D.DUST_PRESENT:
				dusty_cells += 1
		if has_carb:
			var v5: float = carb[c]
			carb_all += v5 * w
			if is_open:
				carb_open += v5 * w
			# CARBONATE-BEARING CELLS. A total alone cannot say whether the sink ran weakly everywhere or hard
			# in a few places, and "where does the weathering happen" is the question a carbon sink raises.
			if v5 > 0.0:
				carb_cells += 1
		if has_silica:
			var v6: float = silica[c]
			silica_all += v6 * w
			if is_open:
				silica_open += v6 * w

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
	# before/after of the inclusion fix is readable straight off a single run, not only across two builds.
	out["dust_open_total"] = snappedf(dust_open, 0.01)
	# SIM_REPORT's `dust_cells`, counted here because this pass already walks the channel. It was
	# `LAMaterialField3D.dust_cell_count() { return 0 }` — a gauge that could only ever print zero. The
	# stop-gap replacement (`LAMaterialFieldQueries3D.dust_cell_count()`, a real body with no caller) was
	out["dust_cells"] = dusty_cells
	out["rock_cells"] = solid_cells
	# LA_NO_PLATE_ADVECT=1 rather than by reading it alone. `crust_moved_ref_step` says which step the baseline
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
		"susp": has_susp, "dust": has_dust, "carbonate": has_carb, "silica": has_silica,
	}
	# --- THE TWO NON-SILICATE SPECIES, AND THE LITHOSPHERE'S ELEMENT BOOK ------------------------------------
	out["carbonate_total"] = snappedf(carb_all, 0.0001)
	out["silica_total"] = snappedf(silica_all, 0.0001)
	out["carbonate_open"] = snappedf(carb_open, 0.0001)
	out["silica_open"] = snappedf(silica_open, 0.0001)
	out["carbonate_cells"] = carb_cells
	var mpu: Dictionary = BalanceScript.mol_per_unit()
	var by_channel: Dictionary = {
		"rock_fill": rock_all, "lava": lava_all, "sediment": sed_all, "susp": susp_all, "dust": dust_all,
		"carbonate": carb_all, "silica": silica_all,
	}
	var lith: Dictionary = {}
	for ch in BalanceScript.LITHOSPHERE_CHANNELS:
		var parts: Dictionary = BalanceScript.channel_elements(ch)
		var moles: float = float(by_channel.get(ch, 0.0)) * float(
			mpu.get(int(BalanceScript.INVENTORY_CHANNELS.get(ch, -1)), 1.0))
		for el in parts:
			lith[el] = float(lith.get(el, 0.0)) + moles * float(parts[el])
	for el in lith:
		out["lith_element_" + String(el)] = snappedf(float(lith[el]), 0.01)

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
	# RUN-LONG DRIFT — the headline conservation figure, and its source-corrected twin.
	#
	# THE BASELINE LATCHES ONLY WHEN EVERY LEG OF THE TOTAL IS GENUINELY PRESENT. The condition used to be
	# `_sealed()` alone, while the comment here claimed the mirrors had arrived — and they had not: a
	# demand-gated leg falls back to its CPU mirror, an absent mirror reads as a flat zero, so the baseline
	# latched low and the channel arriving later read as rock being CREATED. Measured after the seal moved onto
	# the field step: mineral_first 32084 against 34095 at the same horizon, +6.3% of "growth" that was the
	# gauge, not the planet. `mineral_first_live` publishes the decision so a zero baseline is visible rather
	# than silent.
	_samples += 1
	var legs_live: bool = has_rock and has_lava and has_sed and has_susp and has_dust and has_carb and has_silica
	out["mineral_first_live"] = legs_live
	if _first_step < 0 and _sealed() and legs_live:
		_first_total = total
		_note_seed("mineral", total)
		_first_src = src
		_first_step = step_index
		_first_ca = float(lith.get("Ca", 0.0))
		_first_si = float(lith.get("Si", 0.0))
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
		if not is_nan(_first_ca) and _first_ca > 0.0:
			out["lith_ca_rel_drift_per_step"] = snappedf(
				(float(lith.get("Ca", 0.0)) - _first_ca) * rinv / _first_ca, 1.0e-12)
		if not is_nan(_first_si) and _first_si > 0.0:
			out["lith_si_rel_drift_per_step"] = snappedf(
				(float(lith.get("Si", 0.0)) - _first_si) * rinv / _first_si, 1.0e-12)
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
		"carbonate_total": 0.0, "silica_total": 0.0, "carbonate_open": 0.0, "silica_open": 0.0,
		"carbonate_cells": 0,
		"lith_element_Ca": 0.0, "lith_element_Si": 0.0, "lith_element_O": 0.0, "lith_element_C": 0.0,
		"lith_ca_rel_drift_per_step": 0.0, "lith_si_rel_drift_per_step": 0.0,
	}


## True once LAMaterialFieldSeal3D has closed the books. Before it, this module publishes totals but latches
## no baseline and reports no run-drift — because until the world is sealed the only thing a drift gauge can
## measure is the planet being assembled.
func _sealed() -> bool:
	return _f != null and _f._seal != null and _f._seal.sealed()


func _note_seed(key: String, value: float) -> void:
	if _f != null and _f._seal != null:
		_f._seal.note_seed({key: value})
