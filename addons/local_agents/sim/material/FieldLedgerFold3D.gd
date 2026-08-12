class_name LAFieldLedgerFold3D
extends RefCounted

## The ONE walk every conserved substance is summed by. Reads the drain probe, weights each channel by the
## cell's own volume in cubic metres, and returns per-channel open/mask-free amounts plus the thermal stock.
##
## No mirror is ever read here. A leg that did not arrive is ABSENT, and `live` says so; the caller refuses
## that substance's total rather than publishing one that is short by whatever failed to arrive.

var _f = null

# Previous sample's per-cell capacity and absolute temperature, for the dU = sum(rc0*dT) + sum(drc*T1) split.
var _prev_rc: PackedFloat32Array = PackedFloat32Array()
var _prev_tk: PackedFloat32Array = PackedFloat32Array()

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


## Drop the per-cell energy baseline, so the next `amounts` call reports no dU terms rather than terms
## measured against a sample taken at some other step.
func clear_energy_prev() -> void:
	_prev_rc = PackedFloat32Array()
	_prev_tk = PackedFloat32Array()


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
	if want_energy and temp.size() != cc:
		return out
	var cell_size: float = float(_f._cell_size)
	if cell_size <= 0.0:
		return out

	# Cell volumes in cubic metres, once. Channel values are intensive; the amount is value * volume, and this
	# grid's cells differ in volume across the shell.
	var grid = _f._sphere
	var have_grid: bool = grid != null and grid.cell_count == cc
	var uniform_m3: float = pow(cell_size, 3.0)
	var vol: PackedFloat64Array = PackedFloat64Array()
	vol.resize(cc)
	var vol_total_m3: float = 0.0
	var open_cells: int = 0
	var solid_cells: int = 0
	for c in cc:
		var v: float = LAFieldTotals.cell_volume_m3(grid, c) if have_grid else uniform_m3
		vol[c] = v
		vol_total_m3 += v
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
		_energy(out, ch, temp, solid, vol, cc)
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


## The thermal stock, in joules: sum over EVERY cell of rc(cell) * volume * absolute temperature, plus the
## exact split of its change into the part temperature moved and the part the capacity mix moved.
func _energy(out: Dictionary, ch: Dictionary, temp: PackedFloat32Array, solid: PackedByteArray,
		vol: PackedFloat64Array, cc: int) -> void:
	var cap_live: Dictionary = LAHeatCapacity.live_map(ch, cc)
	var missing: PackedStringArray = PackedStringArray()
	for name in cap_live:
		if not bool(cap_live[name]):
			missing.append(String(name))
	out["energy_live"] = cap_live
	out["energy_missing"] = missing
	if missing.size() > 0:
		return
	var rc_all: PackedFloat64Array = LAHeatCapacity.field(ch, cc)
	var have_prev: bool = _prev_rc.size() == cc and _prev_tk.size() == cc
	if not have_prev:
		_prev_rc.resize(cc)
		_prev_tk.resize(cc)
	var depth: int = _f._dim_y
	var stock: float = 0.0
	var cap_j_k: float = 0.0
	var d_heat_j: float = 0.0
	var d_cap_j: float = 0.0
	var shell_solid: int = 0
	for c in cc:
		var rc: float = rc_all[c]
		if solid[c] != 0 and c % depth == 0:
			shell_solid += 1
		var tk: float = temp[c] + LAPhysical.KELVIN_OFFSET
		stock += rc * tk * vol[c]
		cap_j_k += rc * vol[c]
		if have_prev:
			d_heat_j += _prev_rc[c] * (tk - _prev_tk[c]) * vol[c]
			d_cap_j += (rc - _prev_rc[c]) * tk * vol[c]
		_prev_rc[c] = rc
		_prev_tk[c] = tk
	out["energy_stock"] = stock
	out["energy_cap_j_k"] = cap_j_k
	out["energy_have_prev"] = have_prev
	out["energy_d_heat_j"] = d_heat_j
	out["energy_d_cap_j"] = d_cap_j
	out["energy_shell_solid"] = shell_solid
	# Per-leg capacities are sums over cells of rc, so they take the mean cell volume; a per-cell split would
	# mean re-walking the field once per leg.
	var cap_raw: Dictionary = LAHeatCapacity.legs(ch, cc)
	var mean_m3: float = (float(out["vol_total_m3"]) / float(cc)) if cc > 0 else 0.0
	var cap_legs: Dictionary = {}
	for k in cap_raw:
		cap_legs[k] = snappedf(float(cap_raw[k]) * mean_m3, 1.0)
	out["energy_cap_legs"] = cap_legs
