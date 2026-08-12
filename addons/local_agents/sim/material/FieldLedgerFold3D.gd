class_name LAFieldLedgerFold3D
extends RefCounted

## The ONE walk every conserved substance is summed by. Reads the drain probe, weights each channel by the
## cell's own volume in cubic metres, and returns per-channel open/mask-free amounts plus the thermal stock.

var _f = null

# Baseline bedrock, and the step it was latched at.
var _rock_ref: PackedFloat32Array = PackedFloat32Array()
var _rock_ref_step: int = -1


func setup(field) -> void:
	_f = field


## Collect the probe armed by the previous call and arm the next. Returns channel name -> array, with an
## EMPTY array for any leg that did not arrive.
func take_legs() -> Dictionary:
	var out: Dictionary = {}
	if _f == null or _f._gpu == null or not _f._gpu.has_method("take_probe"):
		return out
	var cc: int = _f._cell_count
	var want: PackedStringArray = LAFieldLedgerRecords.all_legs()
	var legs: Dictionary = _f._gpu.take_probe()
	_f._gpu.request_probe(want)
	for name in want:
		var arr: PackedFloat32Array = legs.get(name, PackedFloat32Array())
		out[name] = arr if arr.size() == cc else PackedFloat32Array()
	return out


## The step the probe legs were sampled at, which is not the step the report is being written at.
func probe_step(fallback: int) -> int:
	if _f != null and _f._gpu != null and _f._gpu.has_method("probe_step"):
		var s: int = int(_f._gpu.probe_step())
		if s >= 0:
			return s
	return fallback


## Walk the grid once. Returns the per-channel amounts, the counts, and the thermal stock terms.
func fold(ch: Dictionary, step_index: int, sealed: bool, solid: PackedByteArray,
		temp: PackedFloat32Array) -> Dictionary:
	var out: Dictionary = amounts(ch, solid, temp, true)
	if out.is_empty():
		return out
	var cc: int = _f._cell_count
	_count_presence(out, ch, temp, cc)
	_crust(out, ch, cc, step_index, sealed)
	return out


## The per-channel open/mask-free amounts, in cubic metres of channel. `temp` is in degrees Celsius and is
## required only when `want_energy`, which appends the thermal stock and its dU split.
func amounts(ch: Dictionary, solid: PackedByteArray, temp: PackedFloat32Array,
		want_energy: bool) -> Dictionary:
	var out: Dictionary = {}
	if _f == null or _f._cell_count <= 0:
		return out
	var cc: int = _f._cell_count
	if solid.size() != cc:
		return out
	var cell_size: float = float(_f._cell_size)
	if cell_size <= 0.0:
		return out

	# Cell volumes in cubic metres, once. Channel values are intensive; the amount is value * volume. One
	# uniform grid, so one volume.
	var uniform_m3: float = pow(cell_size, 3.0)
	var vol: PackedFloat64Array = PackedFloat64Array()
	vol.resize(cc)
	vol.fill(uniform_m3)
	var vol_total_m3: float = uniform_m3 * float(cc)
	var open_cells: int = 0
	var solid_cells: int = 0
	for c in cc:
		if solid[c] == 0:
			open_cells += 1
		else:
			solid_cells += 1

	var live: Dictionary = {}
	var amt_open: Dictionary = {}
	var amt_all: Dictionary = {}
	for name in ch:
		var a: PackedFloat32Array = ch[name]
		var present: bool = a.size() == cc
		live[name] = present
		if not present:
			continue
		var s_all: float = 0.0
		var s_open: float = 0.0
		for c in cc:
			var av: float = a[c] * vol[c]
			s_all += av
			if solid[c] == 0:
				s_open += av
		amt_all[name] = s_all
		amt_open[name] = s_open

	out["cells"] = cc
	out["open_cells"] = open_cells
	out["solid_cells"] = solid_cells
	out["vol_total_m3"] = vol_total_m3
	out["live"] = live
	out["open"] = amt_open
	out["all"] = amt_all
	if want_energy:
		_energy(out, ch.get("h_j_m3", PackedFloat32Array()), solid, vol, cc)
	return out


## Threshold counts and the snow-line mean. These compare a per-cell FRACTION against a fraction threshold,
## so they stay UNWEIGHTED — multiplying one side by a volume would move the threshold per cell.
func _count_presence(out: Dictionary, ch: Dictionary, temp: PackedFloat32Array, cc: int) -> void:
	var dust: PackedFloat32Array = ch.get("dust", PackedFloat32Array())
	if dust.size() == cc:
		var n_dust: int = 0
		for c in cc:
			if dust[c] > LAMaterialFieldQueries3D.DUST_PRESENT:
				n_dust += 1
		out["dust_cells"] = n_dust
	var carb: PackedFloat32Array = ch.get("carbonate", PackedFloat32Array())
	if carb.size() == cc:
		var n_carb: int = 0
		for c in cc:
			if carb[c] > 0.0:
				n_carb += 1
		out["carbonate_cells"] = n_carb
	var snow: PackedFloat32Array = ch.get("snow", PackedFloat32Array())
	if snow.size() == cc and temp.size() == cc:
		var n_snow: int = 0
		var n_ice: int = 0
		var t_sum: float = 0.0
		for c in cc:
			if snow[c] > LAMaterialField3D.SNOW_PRESENT:
				n_snow += 1
				t_sum += temp[c]
			if snow[c] >= LAMaterialField3D.ICE_DEPTH:
				n_ice += 1
		out["snow_cells"] = n_snow
		out["ice_cells"] = n_ice
		out["snow_line_temp"] = (t_sum / float(n_snow)) if n_snow > 0 else 0.0


## How far rock_fill has travelled since the books closed, as a fraction. Churn, not matter, so UNWEIGHTED.
func _crust(out: Dictionary, ch: Dictionary, cc: int, step_index: int, sealed: bool) -> void:
	var rock: PackedFloat32Array = ch.get("rock_fill", PackedFloat32Array())
	if rock.size() != cc:
		return
	if _rock_ref.size() == cc:
		var moved: float = 0.0
		for c in cc:
			moved += absf(rock[c] - _rock_ref[c])
		out["crust_moved"] = moved * 0.5
		out["crust_ref_step"] = _rock_ref_step
	elif sealed:
		_rock_ref = rock.duplicate()
		_rock_ref_step = step_index


## The thermal stock, in joules: the enthalpy the cells hold. `h` is J/m^3, so the stock is h * volume and
## there is nothing to reconstruct.
func _energy(out: Dictionary, h: PackedFloat32Array, _solid: PackedByteArray,
		vol: PackedFloat64Array, cc: int) -> void:
	if h.size() != cc:
		out["energy_missing"] = PackedStringArray(["h_j_m3"])
		return
	out["energy_missing"] = PackedStringArray()
	var stock: float = 0.0
	for c in cc:
		stock += h[c] * vol[c]
	out["energy_stock"] = stock
