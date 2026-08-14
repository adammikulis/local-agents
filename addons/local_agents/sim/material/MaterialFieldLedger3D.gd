class_name LAMaterialFieldLedger3D
extends RefCounted

## THE conservation ledger. One reduction read off the device, one set of drift books, and a publisher per
## conserved substance — H2O, mineral, the element inventory, and the thermal stock.

const FoldScript: GDScript = preload("res://addons/local_agents/sim/material/FieldLedgerFold3D.gd")
const BooksScript: GDScript = preload("res://addons/local_agents/sim/material/FieldLedgerBooks3D.gd")

var _f = null
var _fold = null
var _books = null
var _samples: int = 0

# Cumulative energy books, zeroed at the sample the thermal baseline latches so the stock change and the
# booked terms span the same window.
var _cum_absorbed: float = 0.0
var _cum_emitted: float = 0.0
var _cum_radiogenic: float = 0.0
var _first_inject_j: float = 0.0
# Last published block, for the consumers that ask the field for one scalar outside the report path.
var _last: Dictionary = {}


func setup(field) -> void:
	_f = field
	_fold = FoldScript.new()
	_fold.setup(field)
	_books = BooksScript.new()
	_books.setup(field)


## Every conserved substance, sampled together. `step_index` is the field's own step counter; drift is
## reported per field step, never per frame.
func report(step_index: int) -> Dictionary:
	var out: Dictionary = {}
	if _f == null or _f._cell_count <= 0:
		return out
	var t0: int = Time.get_ticks_usec()
	var f: Dictionary = _fold.fold()
	if f.is_empty():
		return out
	# The step the reduction ran at, which is not the step the report is being written at.
	var step: int = int(f["step"])
	if step < 0:
		step = step_index
	_samples += 1
	_publish_h2o(out, f, step)
	_publish_mineral(out, f, step)
	_publish_element(out, f, step)
	_publish_energy(out, f, step)
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
	var h2o: float = LAFieldLedgerRecords.sum_of(all, LAFieldLedgerRecords.H2O)
	out["h2o_total"] = snappedf(h2o, 0.01)
	out["h2o_closed_total"] = snappedf(h2o, 0.01)
	if f.has("snow_cells"):
		out["snow_cells"] = f["snow_cells"]
		out["ice_cells"] = f["ice_cells"]
	var r: Array = _books.run("h2o", "h2o", h2o, step)
	if not r.is_empty():
		out["h2o_first"] = snappedf(float(r[0]), 0.01)
		out["h2o_run_drift"] = snappedf(float(r[1]), 0.01)
		out["h2o_rel_drift"] = _rel(float(r[1]), float(r[0]))
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
	out["silicate_total"] = snappedf(float(all["silicate"]), 0.01)
	out["silicate_open_total"] = snappedf(float(open["silicate"]), 0.01)
	out["carbonate_total"] = snappedf(float(all["carbonate"]), 0.0001)
	out["silica_total"] = snappedf(float(all["silica"]), 0.0001)
	out["carbonate_open"] = snappedf(float(open["carbonate"]), 0.0001)
	out["silica_open"] = snappedf(float(open["silica"]), 0.0001)
	out["rock_cells"] = f["solid_cells"]
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

	var r: Array = _books.run("mineral", "mineral", total, step)
	var r_src: Array = _books.run("mineral_src", "", src, step)
	if r.is_empty():
		out["mineral_first_step"] = -1
		return
	out["mineral_first"] = snappedf(float(r[0]), 0.01)
	out["mineral_run_steps"] = int(r[3])
	out["mineral_first_step"] = int(r[4])
	out["mineral_run_drift"] = snappedf(float(r[1]), 0.01)
	out["mineral_rel_drift"] = _rel(float(r[1]), float(r[0]))
	var d_src: float = float(r_src[1]) if not r_src.is_empty() else 0.0
	out["mineral_net_rel_drift"] = _rel(float(r[1]) - d_src, float(r[0]))
	out["lith_ca_rel_drift"] = _rel_run("lith_Ca", float(lith.get("Ca", 0.0)), step)
	out["lith_si_rel_drift"] = _rel_run("lith_Si", float(lith.get("Si", 0.0)), step)


## A residual over the quantity it is a residual OF, dimensionless. Null when the denominator is absent or
## zero: a ratio with no scale is not a measurement, and a bare-SI difference is a gauge no gate can fail on.
static func _rel(numerator: float, denominator: float):
	if not is_finite(numerator) or not is_finite(denominator) or denominator == 0.0:
		return null
	return snappedf(numerator / absf(denominator), 1.0e-12)


## Drift since the sealed baseline of a book, as a fraction of that baseline.
func _rel_run(book: String, value: float, step: int):
	var r: Array = _books.run(book, "", value, step)
	return _rel(float(r[1]), float(r[0])) if not r.is_empty() else null


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
	out["oxidant_total"] = snappedf(oxidant, 0.01)
	out["oxidant_all"] = snappedf(oxidant_all, 0.01)
	out["carbon_closed_total"] = snappedf(closed, 0.01)
	out["carbon_closed_all"] = snappedf(closed_all, 0.01)
	out["carbon_closed_buried"] = snappedf(closed_all - closed, 0.01)

	var open_by: Dictionary = _subset(open, LAFieldLedgerRecords.ELEMENT)
	var all_by: Dictionary = _subset(all, LAFieldLedgerRecords.ELEMENT)
	var elements: Dictionary = LAFieldLedgerRecords.elements_of(open_by)
	for el in elements:
		out["element_" + String(el)] = snappedf(float(elements[el]), 0.01)
	var elements_all: Dictionary = LAFieldLedgerRecords.elements_of(all_by)
	for el_a in elements_all:
		out["element_" + String(el_a) + "_all"] = snappedf(float(elements_all[el_a]), 0.01)
	# Moles of N over every pool that carries it, the atmosphere included, straight off the element sums. A
	# channel amount IS moles, so dividing one by a carbon-to-nitrogen MASS ratio was neither moles nor kg.
	var nitrogen: float = float(elements.get("N", 0.0))
	var nitrogen_all: float = float(elements_all.get("N", 0.0))
	out["n2_total"] = snappedf(float(open["n2"]), 0.01)
	out["n2_all"] = snappedf(float(all["n2"]), 0.01)
	out["nitrogen_total"] = snappedf(nitrogen, 0.01)
	out["nitrogen_all"] = snappedf(nitrogen_all, 0.01)
	out["nitrogen_buried"] = snappedf(nitrogen_all - nitrogen, 0.01)

	# The totals gated by LAMaterialFieldConservation3D are latched MASK-FREE, because a substance moving into
	# rock is buried, not destroyed. `carbon_rel_drift` stays on the open triangle: its job is to localise a
	# leak to one side of the reaction table.
	out["mass_run_steps"] = _run_pair(out, "carbon", "carbon", "carbon", carbon, step)
	_run_pair(out, "o2", "o2", "o2", float(open["o2"]), step)
	_run_pair(out, "fert", "fert", "", float(open["fert"]), step)
	_run_pair(out, "biomass", "biomass", "", float(open["biomass"]), step)
	_run_pair(out, "oxidant", "oxidant", "", oxidant_all, step)
	_run_pair(out, "carbon_closed", "carbon_closed", "", closed_all, step)
	_run_pair(out, "nitrogen", "nitrogen", "", nitrogen_all, step)


## Publish `<name>_first`, the drift since it, and that drift as a FRACTION of it. Returns the run length.
func _run_pair(out: Dictionary, name: String, book: String, seed_key: String, value: float, step: int) -> int:
	var r: Array = _books.run(book, seed_key, value, step)
	if r.is_empty():
		return 0
	out[name + "_first"] = snappedf(float(r[0]), 0.01)
	out[name + "_run_drift"] = snappedf(float(r[1]), 0.01)
	out[name + "_rel_drift"] = _rel(float(r[1]), float(r[0]))
	return int(r[3])


# --- ENERGY ------------------------------------------------------------------------------------------

func _publish_energy(out: Dictionary, f: Dictionary, step: int) -> void:
	out["energy_stock_cells"] = f["cells"]
	var missing: PackedStringArray = f.get("energy_missing", PackedStringArray())
	if missing.size() > 0 or not f.has("energy_stock"):
		out["energy_stock_missing"] = missing
		out["energy_stock"] = null
		return
	var stock: float = float(f["energy_stock"])
	out["energy_stock"] = stock

	# WATTS, off the device. transport.glsl's RADIATE row writes what each cell took in and sent out as
	# J/m^3 for one step; the two reduce rows weight those by cell volume, so the pair arrives in joules
	# over one step and only the step's own real seconds separate it from watts.
	var dt_s: float = LAMaterialFieldSphereStep3D.real_seconds_per_step()
	var has_rad: bool = f.has("rad_absorbed") and f.has("rad_emitted") and f.has("radiogenic") \
		and dt_s > 0.0
	if not has_rad:
		# A missing measurement is missing: with no radiative pair there is nothing to book against.
		out["energy_absorbed_w"] = null
		out["energy_emitted_w"] = null
		out["energy_net_w"] = null
		out["energy_booked"] = null
		out["energy_residual"] = null
		out["energy_residual_rel"] = null
		out["energy_turnover_j"] = null
		return
	var absorbed_w: float = float(f["rad_absorbed"]) / dt_s
	var emitted_w: float = float(f["rad_emitted"]) / dt_s
	var radiogenic_w: float = float(f["radiogenic"]) / dt_s
	out["energy_absorbed_w"] = absorbed_w
	out["energy_emitted_w"] = emitted_w
	out["energy_net_w"] = absorbed_w - emitted_w
	var inject_j: float = 0.0
	if _f._inject != null and _f._inject.queue != null:
		inject_j = float(_f._inject.queue.heat_energy_j)

	var steps: int = _books.elapsed("energy_stock", step)
	var was_latched: bool = _books.first_step_of("energy_stock") >= 0
	var r: Array = _books.run("energy_stock", "energy_j", stock, step)
	out["energy_stock_samples"] = _samples
	out["energy_first_step"] = _books.first_step_of("energy_stock")
	if r.is_empty():
		return
	out["energy_stock_first"] = float(r[0])
	if not was_latched:
		_cum_absorbed = 0.0
		_cum_emitted = 0.0
		_cum_radiogenic = 0.0
		_first_inject_j = inject_j
	elif steps > 0:
		# Rectangle rule over the window, at the flux sampled at its right-hand end, integrated against the
		# real seconds the kernel applies.
		var window_s: float = dt_s * float(steps)
		_cum_absorbed += absorbed_w * window_s
		_cum_emitted += emitted_w * window_s
		_cum_radiogenic += radiogenic_w * window_s
	var run_steps: int = int(r[3])
	out["energy_run_steps"] = run_steps
	if run_steps <= 0:
		return
	var run_drift: float = float(r[1])
	var cum_inject: float = inject_j - _first_inject_j
	var booked: float = _cum_absorbed - _cum_emitted + cum_inject + _cum_radiogenic
	# What entered or left the thermal field over the window, and the only admissible denominator for the
	# residual: read as a fraction of the STOCK, a wholly unaccounted window reports as round-off.
	var turnover: float = _cum_absorbed + _cum_emitted + absf(cum_inject) + absf(_cum_radiogenic)
	out["energy_run_drift"] = run_drift
	out["energy_run_drift_rel"] = _rel(run_drift, stock)
	out["energy_booked"] = booked
	out["energy_residual"] = run_drift - booked
	out["energy_turnover_j"] = turnover
	out["energy_residual_rel"] = _rel(run_drift - booked, turnover)
	out["energy_book_absorbed_j"] = _cum_absorbed
	out["energy_book_emitted_j"] = _cum_emitted
	out["energy_book_inject_j"] = cum_inject
	out["energy_book_radiogenic_j"] = _cum_radiogenic


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
