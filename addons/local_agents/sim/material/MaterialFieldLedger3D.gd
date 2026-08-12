class_name LAMaterialFieldLedger3D
extends RefCounted

## THE conservation ledger. One probe read, one volume-weighted walk, one set of drift books, and a publisher
## per conserved substance — H2O, mineral, the element inventory, and the thermal stock.

const FoldScript: GDScript = preload("res://addons/local_agents/sim/material/FieldLedgerFold3D.gd")
const BooksScript: GDScript = preload("res://addons/local_agents/sim/material/FieldLedgerBooks3D.gd")

var _f = null
var _fold = null
var _books = null
var _samples: int = 0

# Cumulative energy books, zeroed at the sample the thermal baseline latches so the stock change and the
# booked terms span the same window.
var _cum_solar: float = 0.0
var _cum_lw: float = 0.0
var _cum_geo: float = 0.0
var _first_inject_j: float = 0.0
var _first_unsourced_dc: float = 0.0
# Last published block, for the consumers that ask the field for one scalar outside the report path.
var _last: Dictionary = {}


func setup(field) -> void:
	_f = field
	_fold = FoldScript.new()
	_fold.setup(field)
	_books = BooksScript.new()
	_books.setup(field)


## Every conserved substance, sampled together. `step_index` is the field's own step counter; drift is
## reported per field step, never per frame. `flux` is LAMaterialFieldEnergyBudget3D's radiative report.
func report(step_index: int, flux: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	if _f == null or _f._cell_count <= 0:
		return out
	var t0: int = Time.get_ticks_usec()
	var ch: Dictionary = _fold.take_legs()
	if ch.is_empty():
		return out
	var step: int = _fold.probe_step(step_index)
	var f: Dictionary = _fold.fold(ch, step, _books.sealed(), _f._solid, _f._temp)
	if f.is_empty():
		return out
	_samples += 1
	_publish_h2o(out, f, step)
	_publish_mineral(out, f, step)
	_publish_element(out, f, step)
	_publish_energy(out, f, flux, step)
	out["ledger_step"] = step
	out["ledger_samples"] = _samples
	out["ledger_scan_ms"] = snappedf(float(Time.get_ticks_usec() - t0) / 1000.0, 0.01)
	_last = out
	return out


## One published total, for a consumer outside the report path. Returns the last measurement; 0.0 before the
## first one, and 0.0 for a total this ledger refused.
func total(key: String) -> float:
	var v = _last.get(key)
	return float(v) if v is float or v is int else 0.0


# --- H2O ---------------------------------------------------------------------------------------------

func _publish_h2o(out: Dictionary, f: Dictionary, step: int) -> void:
	var live: Dictionary = _live_of(f, LAFieldLedgerRecords.H2O)
	var missing: PackedStringArray = _missing_of(live)
	out["h2o_live"] = live
	if missing.size() > 0:
		out["h2o_missing"] = missing
		out["h2o_total"] = null
		out["h2o_closed_total"] = null
		return
	var all: Dictionary = f["all"]
	out["water_total"] = snappedf(float(all["water"]), 0.01)
	out["snow_total"] = snappedf(float(all["snow"]), 0.01)
	out["soil_total"] = snappedf(float(all["soil"]), 0.01)
	out["h2o_vapour_total"] = snappedf(float(all["moisture"]), 0.01)
	var h2o: float = LAFieldLedgerRecords.sum_of(all, LAFieldLedgerRecords.H2O)
	out["h2o_total"] = snappedf(h2o, 0.01)
	out["h2o_closed_total"] = snappedf(h2o, 0.01)
	if f.has("snow_cells"):
		out["snow_cells"] = f["snow_cells"]
		out["ice_cells"] = f["ice_cells"]
		out["snow_line_temp"] = snappedf(float(f["snow_line_temp"]), 0.1)
	var s: Array = _books.sample("h2o", h2o, step)
	if not s.is_empty():
		out["h2o_drift"] = snappedf(float(s[0]), 0.01)
		out["h2o_drift_per_step"] = snappedf(float(s[1]), 0.001)
		out["h2o_drift_steps"] = int(s[2])
	var r: Array = _books.run("h2o", "h2o", h2o, step)
	if not r.is_empty():
		out["h2o_first"] = snappedf(float(r[0]), 0.01)
		out["h2o_run_drift"] = snappedf(float(r[1]), 0.01)
		out["h2o_run_drift_per_step"] = snappedf(float(r[2]), 0.0001)
		out["h2o_run_steps"] = int(r[3])


# --- MINERAL -----------------------------------------------------------------------------------------

func _publish_mineral(out: Dictionary, f: Dictionary, step: int) -> void:
	var live: Dictionary = _live_of(f, LAFieldLedgerRecords.MINERAL)
	var missing: PackedStringArray = _missing_of(live)
	out["mineral_live"] = live
	if missing.size() > 0:
		out["mineral_missing"] = missing
		out["mineral_total"] = null
		return
	var all: Dictionary = f["all"]
	var open: Dictionary = f["open"]
	var total: float = LAFieldLedgerRecords.sum_of(all, LAFieldLedgerRecords.MINERAL_SUM)
	var open_total: float = LAFieldLedgerRecords.sum_of(open, LAFieldLedgerRecords.MINERAL_SUM)
	out["mineral_total"] = snappedf(total, 0.01)
	out["mineral_open"] = snappedf(open_total, 0.01)
	out["mineral_buried"] = snappedf(total - open_total, 0.01)
	out["rock_fill_total"] = snappedf(float(all["rock_fill"]), 0.01)
	out["lava_total"] = snappedf(float(all["lava"]), 0.01)
	out["sediment_total"] = snappedf(float(all["sediment"]), 0.01)
	out["susp_total"] = snappedf(float(all["susp"]), 0.01)
	out["dust_total"] = snappedf(float(all["dust"]), 0.01)
	out["dust_open_total"] = snappedf(float(open["dust"]), 0.01)
	out["carbonate_total"] = snappedf(float(all["carbonate"]), 0.0001)
	out["silica_total"] = snappedf(float(all["silica"]), 0.0001)
	out["carbonate_open"] = snappedf(float(open["carbonate"]), 0.0001)
	out["silica_open"] = snappedf(float(open["silica"]), 0.0001)
	out["rock_cells"] = f["solid_cells"]
	out["dust_cells"] = f.get("dust_cells", 0)
	out["carbonate_cells"] = f.get("carbonate_cells", 0)
	if f.has("crust_moved"):
		out["crust_moved"] = snappedf(float(f["crust_moved"]), 0.01)
		out["crust_moved_ref_step"] = f["crust_ref_step"]
	var lith: Dictionary = LAFieldLedgerRecords.lith_elements(all)
	for el in lith:
		out["lith_element_" + String(el)] = snappedf(float(lith[el]), 0.01)
	# The admitted source: erupt_source injects mantle lava with no debit anywhere in the field, so it is
	# booked by the injection queue and subtracted before any statement about whether the substrate conserves.
	var src: float = 0.0
	if _f._inject != null and _f._inject.queue != null:
		src = float(_f._inject.queue.mineral_minted)
	out["mineral_src_total"] = snappedf(src, 0.01)
	out["mineral_samples"] = _samples

	var s: Array = _books.sample("mineral", total, step)
	if not s.is_empty():
		out["mineral_drift"] = snappedf(float(s[0]), 0.01)
		out["mineral_drift_per_step"] = snappedf(float(s[1]), 0.0001)
		out["mineral_drift_steps"] = int(s[2])
	var r: Array = _books.run("mineral", "mineral", total, step)
	var r_src: Array = _books.run("mineral_src", "", src, step)
	if r.is_empty():
		out["mineral_first_step"] = -1
		return
	out["mineral_first"] = snappedf(float(r[0]), 0.01)
	out["mineral_run_steps"] = int(r[3])
	out["mineral_first_step"] = int(r[4])
	var run_steps: int = int(r[3])
	if run_steps > 0:
		var rinv: float = 1.0 / float(run_steps)
		out["mineral_run_drift_per_step"] = snappedf(float(r[1]) * rinv, 0.0001)
		var d_src: float = float(r_src[1]) if not r_src.is_empty() else 0.0
		out["mineral_src_per_step"] = snappedf(d_src * rinv, 0.0001)
		out["mineral_net_per_step"] = snappedf((float(r[1]) - d_src) * rinv, 0.0001)
		_rel_drift(out, "lith_ca_rel_drift_per_step", "lith_Ca", float(lith.get("Ca", 0.0)), step, rinv)
		_rel_drift(out, "lith_si_rel_drift_per_step", "lith_Si", float(lith.get("Si", 0.0)), step, rinv)


func _rel_drift(out: Dictionary, key: String, book: String, value: float, step: int, rinv: float) -> void:
	var r: Array = _books.run(book, "", value, step)
	if r.is_empty():
		return
	var first: float = float(r[0])
	if first > 0.0:
		out[key] = snappedf(float(r[1]) * rinv / first, 1.0e-12)


# --- ELEMENT INVENTORY -------------------------------------------------------------------------------

func _publish_element(out: Dictionary, f: Dictionary, step: int) -> void:
	var live: Dictionary = _live_of(f, LAFieldLedgerRecords.ELEMENT)
	var missing: PackedStringArray = _missing_of(live)
	out["mass_live"] = live
	if missing.size() > 0:
		out["mass_missing"] = missing
		for key in ["carbon_total", "o2_total", "oxidant_total", "oxidant_all",
				"carbon_closed_total", "nitrogen_total", "nitrogen_all"]:
			out[key] = null
		return
	var all: Dictionary = f["all"]
	var open: Dictionary = f["open"]
	var carbon: float = LAFieldLedgerRecords.sum_of(open, LAFieldLedgerRecords.CARBON)
	var carbon_all: float = LAFieldLedgerRecords.sum_of(all, LAFieldLedgerRecords.CARBON)
	out["carbon_total"] = snappedf(carbon, 0.01)
	out["carbon_all"] = snappedf(carbon_all, 0.01)
	out["carbon_buried"] = snappedf(carbon_all - carbon, 0.01)
	out["carbon_co2"] = snappedf(float(open["co2"]), 0.01)
	out["carbon_biomass"] = snappedf(float(open["biomass"]), 0.01)
	out["carbon_detritus"] = snappedf(float(open["detritus"]), 0.01)
	out["o2_total"] = snappedf(float(open["o2"]), 0.01)
	out["o2_all"] = snappedf(float(all["o2"]), 0.01)
	out["fert_total"] = snappedf(float(open["fert"]), 0.01)
	out["fert_all"] = snappedf(float(all["fert"]), 0.01)
	out["biomass_open_total"] = snappedf(float(open["biomass"]), 0.01)
	out["fungus_total"] = snappedf(float(open["fungus"]), 0.01)
	out["fungus_all"] = snappedf(float(all["fungus"]), 0.01)
	out["fuel_open_total"] = snappedf(float(open["fuel"]), 0.01)
	out["fuel_all"] = snappedf(float(all["fuel"]), 0.01)
	out["mass_open_cells"] = f["open_cells"]

	var oxidant: float = LAFieldLedgerRecords.sum_of(open, LAFieldLedgerRecords.OXIDANT)
	var oxidant_all: float = LAFieldLedgerRecords.sum_of(all, LAFieldLedgerRecords.OXIDANT)
	var closed: float = LAFieldLedgerRecords.sum_of(open, LAFieldLedgerRecords.CARBON_CLOSED)
	var closed_all: float = LAFieldLedgerRecords.sum_of(all, LAFieldLedgerRecords.CARBON_CLOSED)
	var n_org: float = LAFieldLedgerRecords.sum_of(open, LAFieldLedgerRecords.NITROGEN_ORGANIC)
	var n_org_all: float = LAFieldLedgerRecords.sum_of(all, LAFieldLedgerRecords.NITROGEN_ORGANIC)
	var nitrogen: float = float(open["fert"]) + n_org / LAPhysical.LITTER_C_TO_N
	var nitrogen_all: float = float(all["fert"]) + n_org_all / LAPhysical.LITTER_C_TO_N
	out["oxidant_total"] = snappedf(oxidant, 0.01)
	out["oxidant_all"] = snappedf(oxidant_all, 0.01)
	out["carbon_closed_total"] = snappedf(closed, 0.01)
	out["carbon_closed_all"] = snappedf(closed_all, 0.01)
	out["carbon_closed_buried"] = snappedf(closed_all - closed, 0.01)
	out["nitrogen_total"] = snappedf(nitrogen, 0.01)
	out["nitrogen_all"] = snappedf(nitrogen_all, 0.01)
	out["nitrogen_buried"] = snappedf(nitrogen_all - nitrogen, 0.01)

	var open_by: Dictionary = _subset(open, LAFieldLedgerRecords.ELEMENT)
	var all_by: Dictionary = _subset(all, LAFieldLedgerRecords.ELEMENT)
	var elements: Dictionary = LAFieldLedgerRecords.elements_of(open_by)
	for el in elements:
		out["element_" + String(el)] = snappedf(float(elements[el]), 0.01)
	var elements_all: Dictionary = LAFieldLedgerRecords.elements_of(all_by)
	for el_a in elements_all:
		out["element_" + String(el_a) + "_all"] = snappedf(float(elements_all[el_a]), 0.01)

	var steps: int = 0
	for pair in [["carbon", carbon], ["o2", float(open["o2"])], ["fert", float(open["fert"])],
			["biomass", float(open["biomass"])]]:
		var s: Array = _books.sample(String(pair[0]), float(pair[1]), step)
		if s.is_empty():
			continue
		out[String(pair[0]) + "_drift"] = snappedf(float(s[0]), 0.01)
		out[String(pair[0]) + "_drift_per_step"] = snappedf(float(s[1]), 0.0001)
		steps = int(s[2])
	if steps > 0:
		out["mass_drift_steps"] = steps

	# The three totals gated by LAMaterialFieldConservation3D are latched MASK-FREE, because a substance
	# moving into rock is buried, not destroyed. `carbon_run_drift_per_step` stays on the open triangle: its
	# job is to localise a leak to one side of the reaction table.
	out["mass_run_steps"] = _run_pair(out, "carbon", "carbon", "carbon", carbon, step)
	_run_pair(out, "o2", "o2", "o2", float(open["o2"]), step)
	_run_pair(out, "fert", "fert", "", float(open["fert"]), step)
	_run_pair(out, "biomass", "biomass", "", float(open["biomass"]), step)
	_run_pair(out, "oxidant", "oxidant", "", oxidant_all, step)
	_run_pair(out, "carbon_closed", "carbon_closed", "", closed_all, step)
	_run_pair(out, "nitrogen", "nitrogen", "", nitrogen_all, step)


## Publish `<name>_first` and `<name>_run_drift_per_step` from one book. Returns the run length in steps.
func _run_pair(out: Dictionary, name: String, book: String, seed_key: String, value: float, step: int) -> int:
	var r: Array = _books.run(book, seed_key, value, step)
	if r.is_empty():
		return 0
	out[name + "_first"] = snappedf(float(r[0]), 0.01)
	var steps: int = int(r[3])
	if steps > 0:
		out[name + "_run_drift_per_step"] = snappedf(float(r[2]), 0.0001)
	return steps


# --- ENERGY ------------------------------------------------------------------------------------------

func _publish_energy(out: Dictionary, f: Dictionary, flux: Dictionary, step: int) -> void:
	out["energy_stock_cells"] = f["cells"]
	out["energy_stock_live"] = f.get("energy_live", {})
	var missing: PackedStringArray = f.get("energy_missing", PackedStringArray())
	if missing.size() > 0 or not f.has("energy_stock"):
		out["energy_stock_missing"] = missing
		out["energy_stock"] = null
		return
	var stock: float = float(f["energy_stock"])
	out["energy_stock"] = stock
	out["energy_geo_shell_cells"] = f["energy_shell_solid"]

	# Booked rates, in watts. LAMaterialFieldEnergyBudget3D sums each cell's flux against that cell's own
	# outward face area in square metres, so these arrive as watts and need no conversion.
	var solar_w: float = float(flux.get("energy_absorbed_w", 0.0))
	var lw_w: float = float(flux.get("energy_emitted_w", 0.0))
	var geo_w: float = _geo_watts(int(f["energy_shell_solid"]), int(f["cells"]))
	var inject_j: float = 0.0
	var unsourced_dc: float = 0.0
	if _f._inject != null and _f._inject.queue != null:
		inject_j = float(_f._inject.queue.heat_energy_j)
		unsourced_dc = float(_f._inject.queue.heat_unsourced_dc)

	var s: Array = _books.sample("energy_stock", stock, step)
	var steps: int = int(s[2]) if not s.is_empty() else 0
	if not s.is_empty():
		out["energy_drift"] = float(s[0])
		out["energy_drift_per_step"] = float(s[1])
		out["energy_drift_steps"] = steps
	var was_latched: bool = _books.first_step_of("energy_stock") >= 0
	var r: Array = _books.run("energy_stock", "energy_j", stock, step)
	out["energy_stock_samples"] = _samples
	out["energy_first_step"] = _books.first_step_of("energy_stock")
	if r.is_empty():
		return
	out["energy_stock_first"] = float(r[0])
	if not was_latched:
		_cum_solar = 0.0
		_cum_lw = 0.0
		_cum_geo = 0.0
		_first_inject_j = inject_j
		_first_unsourced_dc = unsourced_dc
	elif steps > 0:
		# Rectangle rule over the window, at the flux sampled at its right-hand end, integrated against the
		# real seconds the kernel applies.
		var window_s: float = LAMaterialFieldSphereStep3D.real_seconds_per_step() * float(steps)
		_cum_solar += solar_w * window_s
		_cum_lw += lw_w * window_s
		_cum_geo += geo_w * window_s
	out["energy_unsourced_dc"] = unsourced_dc - _first_unsourced_dc
	var run_steps: int = int(r[3])
	out["energy_run_steps"] = run_steps
	if run_steps <= 0:
		return
	var run_drift: float = float(r[1])
	var cum_inject: float = inject_j - _first_inject_j
	var booked: float = _cum_solar - _cum_lw + _cum_geo + cum_inject
	out["energy_run_drift"] = run_drift
	out["energy_run_drift_per_step"] = run_drift / float(run_steps)
	out["energy_booked"] = booked
	out["energy_residual"] = run_drift - booked
	# The decomposition's own check: sum(rc0*dT) + sum(drc*T1) is the stock change identically, so this is
	# near zero or the split is wrong.
	var area: float = float(flux.get("energy_face_area_m2", 0.0))
	out["energy_ref_area_m2"] = area
	var run_s: float = LAMaterialFieldSphereStep3D.real_seconds_per_step() * float(run_steps)
	if area <= 0.0 or run_s <= 0.0:
		return
	var inv: float = 1.0 / (area * run_s)
	out["energy_drift_w_m2"] = run_drift * inv
	out["energy_booked_w_m2"] = booked * inv
	out["energy_residual_w_m2"] = (run_drift - booked) * inv
	out["energy_book_solar_w_m2"] = _cum_solar * inv
	out["energy_book_lw_w_m2"] = _cum_lw * inv
	out["energy_book_geo_w_m2"] = _cum_geo * inv
	out["energy_book_inject_w_m2"] = cum_inject * inv


## The geotherm's scalar flux crosses the deepest solid faces, one cell face each.
func _geo_watts(shell_solid: int, _cc: int) -> float:
	if _f._geotherm == null or _f._grid == null:
		return 0.0
	var geo_flux: float = float(_f._geotherm.report().get("core_flux_w_m2", 0.0))
	return geo_flux * _f._grid.face_area() * float(shell_solid)


# --- shared ------------------------------------------------------------------------------------------

func _live_of(f: Dictionary, group: PackedStringArray) -> Dictionary:
	var live: Dictionary = f["live"]
	var out: Dictionary = {}
	for name in group:
		out[name] = bool(live.get(name, false))
	return out


func _missing_of(live: Dictionary) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for name in live:
		if not bool(live[name]):
			out.append(String(name))
	return out


func _subset(by_channel: Dictionary, group: PackedStringArray) -> Dictionary:
	var out: Dictionary = {}
	for name in group:
		out[name] = float(by_channel.get(name, 0.0))
	return out
