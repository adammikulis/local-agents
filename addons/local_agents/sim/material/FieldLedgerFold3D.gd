class_name LAFieldLedgerFold3D
extends RefCounted

## The ledger's reading of the field's own reduction: LAReduceRecords declares the rows, ReducePass runs
## them on the device, and this reshapes the drained keys into per-channel books. A row whose buffer was
## absent has no key here and its consumer publishes null, because a missing measurement is missing.

var _f = null


func setup(field) -> void:
	_f = field


## Per-channel open/mask-free amounts, the counts, and the thermal stock, all off the device.
func fold() -> Dictionary:
	var out: Dictionary = {}
	if _f == null or _f._cell_count <= 0 or _f._gpu == null:
		return out
	if not _f._gpu.has_method("take_pass_results"):
		return out
	var r: Dictionary = _f._gpu.take_pass_results()
	if r.is_empty():
		return out
	var live: Dictionary = {}
	var amt_all: Dictionary = {}
	var amt_open: Dictionary = {}
	for name in LAReduceRecords.AMOUNTS:
		var present: bool = r.has("all_" + name) and r.has("open_" + name)
		live[name] = present
		if not present:
			continue
		amt_all[name] = float(r["all_" + name])
		amt_open[name] = float(r["open_" + name])
	out["live"] = live
	out["all"] = amt_all
	out["open"] = amt_open
	out["step"] = int(r.get("reduce_step", -1.0))
	if r.has("carbonate_cells"):
		out["carbonate_cells"] = int(r["carbonate_cells"])
	if r.has("snow_cells") and r.has("ice_cells"):
		out["snow_cells"] = int(r["snow_cells"])
		out["ice_cells"] = int(r["ice_cells"])
	# Half, because a cell that gained rock is matched by one that lost it.
	if r.has("crust_moved") and int(r.get("crust_ref_step", -1.0)) >= 0:
		out["crust_moved"] = float(r["crust_moved"]) * 0.5
		out["crust_ref_step"] = int(r["crust_ref_step"])
	if r.has("charge_stock") and r.has("charge_gross"):
		out["charge_stock"] = float(r["charge_stock"])
		out["charge_gross"] = float(r["charge_gross"])
	# The stores the world's energy is the sum of; one the device did not deliver is named, never skipped.
	var want: PackedStringArray = PackedStringArray(["energy_stock", "energy_stock_open", "energy_kinetic", "energy_potential", "energy_pv_solid", "energy_pv_fluid"])
	for row: Dictionary in LAProcessSet.reduce_rows():
		if bool(row.get("energy_book", false)):
			want.append(String(row["key"]))
	var absent: PackedStringArray = PackedStringArray()
	for key: String in want:
		if r.has(key):
			out[key] = float(r[key])
		else:
			absent.append(key)
	out["energy_missing"] = absent
	# The edge crossings, per channel per step, positive INTO the domain. LABoundaryBooks integrates them
	# and names any leg a row promised and the drain did not carry.
	for key in r:
		if String(key).begins_with(LABoundaryBooks.AMOUNT):
			out[String(key)] = float(r[key])
	out["bnd_declared"] = LABoundaryBooks.declared()
	return out
