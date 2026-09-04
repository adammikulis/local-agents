class_name LAMaterialFieldLedger3D
extends RefCounted

## THE conservation ledger. One reduction read off the device, one set of drift books, and a publisher per
## conserved substance — H2O, mineral, the element inventory, and the thermal stock.

const FoldScript: GDScript = preload("res://addons/local_agents/sim/material/FieldLedgerFold3D.gd")
const BooksScript: GDScript = preload("res://addons/local_agents/sim/material/FieldLedgerBooks3D.gd")
const BndScript: GDScript = preload("res://addons/local_agents/sim/material/reduce/BoundaryBooks.gd")

var _f = null
var _fold = null
var _books = null

# Cumulative energy books, zeroed at the sample the thermal baseline latches so the stock change and the
# booked terms span the same window.
var _cum_absorbed: float = 0.0
var _cum_emitted: float = 0.0
var _cum_radiogenic: float = 0.0
var _first_inject_j: float = 0.0
var _bnd = null
## The stock baselines have latched, so the crossing integral may open.
var _latched: bool = false
# Last published block, for the consumers that ask the field for one scalar outside the report path.
var _last: Dictionary = {}
# The last drain this ledger folded. The publishers read it; nothing else may fold.
var _latest: Dictionary = {}


func setup(field) -> void:
	_f = field
	_fold = FoldScript.new()
	_fold.setup(field)
	_books = BooksScript.new()
	_books.setup(field)
	_bnd = BndScript.new()


## ONE drain, folded on the field step. take_pass_results CONSUMES, so a drain nobody folds is a step's
## crossings thrown away — and a crossing is a flux, which only integrates if every step is counted.
func sample() -> void:
	var f: Dictionary = _fold.fold()
	if f.is_empty():
		return
	_latest = f
	if not _books.sealed():
		return
	# The baselines latch on the fold the crossing integral opens on, so drift and crossings span the same
	# steps; this fold's own crossings are already inside the stock it latched.
	if not _latched:
		_latched = true
		report(int(f["step"]))
		return
	_bnd.sample(f)


## Every conserved substance, published together from the last fold. A stock may be read on any cadence;
## `step_index` is the field's own step counter, never a frame.
func report(step_index: int) -> Dictionary:
	var out: Dictionary = {}
	if _f == null or _f._cell_count <= 0 or _latest.is_empty():
		return out
	var f: Dictionary = _latest
	# The step the reduction ran at, which is not the step the report is being written at.
	var step: int = int(f["step"])
	if step < 0:
		step = step_index
	out["bnd_declared"] = f.get("bnd_declared", PackedStringArray())
	_publish_h2o(out, f, step)
	_publish_mineral(out, f, step)
	_publish_element(out, f, step)
	_publish_energy(out, f, step)
	_publish_charge(out, f, step)
	_last = out
	return out


## One published total, for a consumer outside the report path. Returns the last measurement; 0.0 before the
## first one, and 0.0 for a total this ledger refused.
func total(key: String) -> float:
	var v = _last.get(key)
	return float(v) if v is float or v is int else 0.0


# --- H2O ---------------------------------------------------------------------------------------------

func _publish_h2o(out: Dictionary, f: Dictionary, step: int) -> void:
	if _absent(f, LAFieldLedgerRecords.H2O):
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
	_run_pair(out, "h2o", "h2o", "h2o", h2o, step, _bnd.of(LAFieldLedgerRecords.H2O))


# --- MINERAL -----------------------------------------------------------------------------------------

func _publish_mineral(out: Dictionary, f: Dictionary, step: int) -> void:
	out["mineral_live"] = _live_of(f, LAFieldLedgerRecords.MINERAL)
	if _absent(f, LAFieldLedgerRecords.MINERAL):
		out["mineral_total"] = null
		return
	var lith: Dictionary = LAFieldLedgerRecords.lith_elements(f["all"])
	var total: float = float(lith.get("Si", 0.0))
	out["mineral_total"] = snappedf(total, 0.01)
	out["carbonate_cells"] = f.get("carbonate_cells", 0)
	if f.has("crust_moved"):
		out["crust_moved"] = snappedf(float(f["crust_moved"]), 0.01)
	for el in lith:
		out["lith_element_" + String(el)] = snappedf(float(lith[el]), 0.01)
	# erupt_source injects mantle lava with no debit in the field, so the queue books it.
	var src: float = 0.0
	if _f._inject != null and _f._inject.queue != null:
		src = float(_f._inject.queue.mineral_minted)
	out["mineral_src_total"] = snappedf(src, 0.01)
	_run_pair(out, "mineral", "mineral", "mineral", total, step,
		_bnd.of(LAFieldLedgerRecords.MINERAL, "Si"))
	# Every conserved element of the seeded rock gets its own drift book, keyed on its lith moles.
	for el in ["Fe", "Mg", "Al", "Na", "Cl", "P"]:
		_run_pair(out, "lith_" + el, "lith_" + el, "", float(lith.get(el, 0.0)), step,
			_bnd.of(LAFieldLedgerRecords.MINERAL, el))
	_publish_daughters(out, f)


## Radiogenic daughters accumulated in the rock since the planet formed, moles: the parents' traces
## decay in closed form, so the He and Ar the rock holds are computed, never seeded.
func _publish_daughters(out: Dictionary, f: Dictionary) -> void:
	var epoch: float = LARadiogenicDecay.epoch_years()
	var table: Dictionary = LASubstances.table()
	var rows: Dictionary = LAChannels.rows()
	var all: Dictionary = f["all"]
	var acc: Dictionary = {}
	for ch in LAFieldLedgerRecords.MINERAL:
		var amount = all.get(ch)
		if amount == null:
			continue
		var s: Dictionary = table.get(String(rows[ch].get("substance", "")), {})
		var kg: float = float(amount) * float(s.get("molar_mass", 0.0))
		var d: Dictionary = LARadiogenicDecay.daughters_mol_per_kg(s.get("traces", {}), epoch)
		for el in d:
			acc[el] = float(acc.get(el, 0.0)) + kg * float(d[el])
	for el in acc:
		out["radiogenic_" + String(el) + "_mol"] = snappedf(float(acc[el]), 1e-6)


## A residual over the quantity it is a residual OF, dimensionless. Anything appearing in an empty stock
## that saw no crossing is wholly unaccounted.
static func _rel(numerator: float, denominator: float):
	if not is_finite(numerator) or not is_finite(denominator):
		return null
	if denominator == 0.0:
		return float(numerator != 0.0)
	return snappedf(numerator / absf(denominator), 1.0e-12)


# --- ELEMENT INVENTORY -------------------------------------------------------------------------------

func _publish_element(out: Dictionary, f: Dictionary, step: int) -> void:
	out["mass_live"] = _live_of(f, LAFieldLedgerRecords.ELEMENT)
	if _absent(f, LAFieldLedgerRecords.ELEMENT):
		for key in ["carbon_total", "o2_total", "oxidant_total", "oxidant_all", "nitrogen_all"]:
			out[key] = null
		return
	var all: Dictionary = f["all"]
	var open: Dictionary = f["open"]
	var carbon: float = LAFieldLedgerRecords.sum_of(open, LAFieldLedgerRecords.CARBON)
	var oxidant_all: float = LAFieldLedgerRecords.sum_of(all, LAFieldLedgerRecords.OXIDANT)
	var closed_all: float = LAFieldLedgerRecords.sum_of(all, LAFieldLedgerRecords.CARBON_CLOSED)
	out["carbon_total"] = snappedf(carbon, 0.01)
	out["o2_total"] = snappedf(float(open["o2"]), 0.01)
	out["oxidant_total"] = snappedf(LAFieldLedgerRecords.sum_of(open, LAFieldLedgerRecords.OXIDANT), 0.01)
	out["oxidant_all"] = snappedf(oxidant_all, 0.01)

	var elements: Dictionary = LAFieldLedgerRecords.elements_of(
		_subset(open, LAFieldLedgerRecords.ELEMENT))
	for el in elements:
		out["element_" + String(el)] = snappedf(float(elements[el]), 0.01)
	# A channel amount IS moles, so nothing is converted: element_N_all is the nitrogen over every pool.
	var elements_all: Dictionary = LAFieldLedgerRecords.elements_of(
		_subset(all, LAFieldLedgerRecords.ELEMENT))
	for el_a in elements_all:
		out["element_" + String(el_a) + "_all"] = snappedf(float(elements_all[el_a]), 0.01)
	var nitrogen_all: float = float(elements_all.get("N", 0.0))
	out["nitrogen_all"] = snappedf(nitrogen_all, 0.01)

	# The gated totals are latched MASK-FREE: a substance moving into rock is buried, not destroyed.
	# `carbon_rel_drift` stays on the open triangle, to localise a leak to one side of the reaction table.
	_run_pair(out, "carbon", "carbon", "carbon", carbon, step, _bnd.of(LAFieldLedgerRecords.CARBON))
	_run_pair(out, "o2", "o2", "o2", float(open["o2"]), step, _bnd.of(PackedStringArray(["o2"])))
	_run_pair(out, "fert", "fert", "", float(open["fert"]), step, _bnd.of(PackedStringArray(["fert"])))
	_run_pair(out, "biomass", "biomass", "", float(open["biomass"]), step,
		_bnd.of(PackedStringArray(["biomass"])))
	_run_pair(out, "oxidant", "oxidant", "", oxidant_all, step, _bnd.of(LAFieldLedgerRecords.OXIDANT))
	_run_pair(out, "carbon_closed", "carbon_closed", "", closed_all, step,
		_bnd.of(LAFieldLedgerRecords.CARBON_CLOSED))
	_run_pair(out, "nitrogen", "nitrogen", "", nitrogen_all, step,
		_bnd.of(LAFieldLedgerRecords.ELEMENT, "N"))
	# Elemental H over every pool water included: what Jeans escape drains, closed by its bnd legs.
	var h_pool: PackedStringArray = LAFieldLedgerRecords.ELEMENT.duplicate()
	h_pool.append_array(LAFieldLedgerRecords.H2O)
	_run_pair(out, "hydrogen", "hydrogen", "",
		float(LAFieldLedgerRecords.elements_of(_subset(all, h_pool)).get("H", 0.0)), step,
		_bnd.of(h_pool, "H"))


## `<name>_first`, the drift since it, the crossing booked against it, and the residual `drift - net in`
## over the baseline plus what crossed. A non-negative `scale` replaces that denominator, for a quantity
## whose conserved value is ZERO and whose baseline is therefore residue. Returns the run length.
func _run_pair(out: Dictionary, name: String, book: String, seed_key: String, value: float, step: int,
		bnd: Array, scale: float = -1.0) -> int:
	var r: Array = _books.run(book, seed_key, value, step)
	if r.is_empty():
		return 0
	out[name + "_first"] = snappedf(float(r[0]), 0.01)
	out[name + "_run_drift"] = snappedf(float(r[1]), 0.01)
	out[name + "_bnd_in"] = float(bnd[0])
	out[name + "_bnd_crossed"] = float(bnd[1])
	var denom: float = scale if scale >= 0.0 else absf(float(r[0])) + float(bnd[1])
	out[name + "_rel_drift"] = null if bool(bnd[2]) else _rel(float(r[1]) - float(bnd[0]), denom)
	return int(r[3])


# --- ENERGY ------------------------------------------------------------------------------------------

func _publish_energy(out: Dictionary, f: Dictionary, step: int) -> void:
	var missing: PackedStringArray = f.get("energy_missing", PackedStringArray())
	if missing.size() > 0 or not f.has("energy_stock") or not f.has("energy_stock_lith"):
		out["energy_stock"] = null
		return
	# THE FIRST LAW'S TOTAL: both reservoirs' internal energy plus motion plus potential.
	out["energy_stock"] = float(f["energy_stock"]) + float(f["energy_stock_lith"])
	out["energy_stock_open"] = float(f["energy_stock_open"]) + float(f["energy_stock_open_lith"]) if f.has("energy_stock_open_lith") else null
	out["energy_held"] = float(out["energy_stock"]) + float(f["energy_kinetic"]) + float(f["energy_potential"])

	# WATTS, off the device. flux.glsl's RADIATE row writes what each cell took in and sent out as
	# J/m^3 for one step; the two reduce rows weight those by cell volume, so the pair arrives in joules
	# over one step and only the step's own real seconds separate it from watts.
	var dt_s: float = LAMaterialFieldSphereStep3D.real_seconds_per_step()
	var has_rad: bool = f.has("rad_absorbed") and f.has("rad_emitted") and f.has("radiogenic") \
		and dt_s > 0.0
	# A world that declares no radiative record exchanges nothing by radiation; one that declares it
	# and publishes no reading is unmeasured.
	var rad_declared: bool = LAProcessSet.has_record("transport", "heat_radiate")
	var absorbed_w: float = float(f.get("rad_absorbed", 0.0)) / dt_s if has_rad else 0.0
	var emitted_w: float = float(f.get("rad_emitted", 0.0)) / dt_s if has_rad else 0.0
	var radiogenic_w: float = float(f.get("radiogenic", 0.0)) / dt_s if has_rad else 0.0
	out["energy_net_w"] = (absorbed_w - emitted_w) if has_rad else null
	var inject_j: float = 0.0
	if _f._inject != null and _f._inject.queue != null:
		inject_j = float(_f._inject.queue.heat_energy_j)

	# THE STOCK AND ITS DRIFT STAND WITHOUT THE RADIATIVE PAIR. A world whose processes do not include
	# radiation exchanges no energy with anything, so what it holds must not move; only the RESIDUAL —
	# the drift net of what was booked — needs terms to book against.
	var steps: int = _books.elapsed("energy_held", step)
	var was_latched: bool = _books.first_step_of("energy_held") >= 0
	var r: Array = _books.run("energy_held", "energy_j", float(out["energy_held"]), step)
	if r.is_empty():
		return
	out["energy_held_first"] = float(r[0])
	out["energy_run_drift"] = float(r[1])
	out["energy_run_drift_rel"] = _rel(float(r[1]), absf(float(r[0])))
	if rad_declared and not has_rad:
		# A missing measurement is missing: the declared radiative pair published no reading.
		for key in ["energy_booked", "energy_residual", "energy_residual_rel", "energy_turnover_j"]:
			out[key] = null
		return
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
	if int(r[3]) <= 0:
		return
	var run_drift: float = float(r[1])
	var cum_inject: float = inject_j - _first_inject_j
	# The joules that crossed the open edge with the matter. POSITIVE IS INTO the domain, so they are booked
	# with the same sign as absorbed sunlight; zero while the wall is shut.
	var booked: float = _cum_absorbed - _cum_emitted + cum_inject + _cum_radiogenic + _bnd.heat_net
	# What entered or left the thermal field over the window, and the only admissible denominator for the
	# residual: read as a fraction of the STOCK, a wholly unaccounted window reports as round-off.
	var turnover: float = _cum_absorbed + _cum_emitted + absf(cum_inject) + absf(_cum_radiogenic) \
		+ _bnd.heat_gross
	out["energy_booked"] = booked
	out["energy_residual"] = run_drift - booked
	out["energy_turnover_j"] = turnover
	out["energy_bnd_in"] = _bnd.heat_net
	out["energy_bnd_crossed"] = _bnd.heat_gross
	out["energy_residual_rel"] = null if not _bnd.missing.is_empty() \
		else _rel(run_drift - booked, turnover)


# --- CHARGE ------------------------------------------------------------------------------------------

## Net charge over the box, coulombs: no heat leg, so the edge crossing books amount-only. Riming separates
## it in ZERO-SUM pairs, so the net is a residual whose scale is the charge that EXISTS.
func _publish_charge(out: Dictionary, f: Dictionary, step: int) -> void:
	if not f.has("charge_stock"):
		out["charge_stock"] = null
		out["charge_gross"] = null
		return
	var gross: float = float(f["charge_gross"])
	out["charge_stock"] = float(f["charge_stock"])
	out["charge_gross"] = gross
	_run_pair(out, "charge", "charge", "charge_c", float(f["charge_stock"]), step,
		_bnd.of(PackedStringArray(["charge"])), gross)


# --- shared ------------------------------------------------------------------------------------------

func _live_of(f: Dictionary, group: PackedStringArray) -> Dictionary:
	var live: Dictionary = f["live"]
	var out: Dictionary = {}
	for name in group:
		out[name] = bool(live.get(name, false))
	return out


## True when any channel of the group did not arrive from the drain. A missing measurement is missing, so
## its consumer publishes null rather than a total summed over the legs that happened to turn up.
func _absent(f: Dictionary, group: PackedStringArray) -> bool:
	var live: Dictionary = f["live"]
	for name in group:
		if not bool(live.get(name, false)):
			return true
	return false


func _subset(by_channel: Dictionary, group: PackedStringArray) -> Dictionary:
	var out: Dictionary = {}
	for name in group:
		out[name] = float(by_channel.get(name, 0.0))
	return out
