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
	var cc: int = _f._cell_count
	# `solid` is 0 or 1 on the device (state_derive.glsl), so every cell is open or solid.
	var solid_cells: int = int(r.get("solid_cells", 0.0))
	out["cells"] = cc
	out["solid_cells"] = solid_cells
	out["open_cells"] = cc - solid_cells
	out["vol_total_m3"] = pow(float(_f._cell_size), 3.0) * float(cc)
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
	if r.has("energy_stock"):
		out["energy_missing"] = PackedStringArray()
		out["energy_stock"] = float(r["energy_stock"])
	else:
		out["energy_missing"] = PackedStringArray(["h_j_m3"])
	# The RADIATE row's own books, and the radiogenic source's: joules over one step, volume-weighted.
	for key in ["rad_absorbed", "rad_emitted", "radiogenic"]:
		if r.has(key):
			out[key] = float(r[key])
	return out
