class_name LAFieldPassProbe3D
extends RefCounted


## Totals ONE channel after EVERY pass, for the first few steps. `LA_PASS_PROBE=o2`. Volume-weighted: a
## channel value is a fill FRACTION, so a bare buffer sum moves when transport conserves matter.

const DEFAULT_STEPS: int = 3

var _f = null
var _channel: String = ""
var _steps: int = DEFAULT_STEPS
var _step: int = 0


func setup(field) -> void:
	_f = field
	_channel = OS.get_environment("LA_PASS_PROBE")
	var n: String = OS.get_environment("LA_PASS_PROBE_STEPS")
	if n != "":
		_steps = maxi(1, int(n))


func armed() -> bool:
	return _channel != ""


## Arms the driver's between-pass probe while there are steps left to sample, and disarms after, so the
## normal one-submit path is what runs for the rest of the run.
func pre_step() -> void:
	if _f == null or _f._gpu == null or not _f._gpu.has_method("set_step_probe"):
		return
	if _step >= _steps:
		_f._gpu.set_step_probe(Callable())
		return
	_f._gpu.set_step_probe(Callable(self, "_on_pass"))


func post_step() -> void:
	if _step < _steps:
		_step += 1


func _on_pass(pass_index: int, pass_name: String) -> void:
	var amount: float = _total()
	# A NaN total is the reading, not a reason to stay silent.
	print("PASS_PROBE=", JSON.stringify({
		"step": _step, "pass": pass_name if pass_index >= 0 else "start",
		"channel": _channel, "amount": amount if is_finite(amount) else String.num(amount),
		"peak": _peak()}))


## The cell where |channel| peaks (or `LA_PASS_PROBE_CELL`), with the state that decides its dynamics.
func _peak() -> Dictionary:
	var one: PackedFloat32Array = _f._gpu.read_raw(_channel)
	if one.size() != _f._cell_count:
		return {}
	var at: int = 0
	var top: float = 0.0
	var pin: String = OS.get_environment("LA_PASS_PROBE_CELL")
	if pin != "":
		at = clampi(int(pin), 0, one.size() - 1)
	# `LA_PASS_PROBE_REF=<buffer>`: peak on |channel - ref| / |ref| instead of on the channel itself.
	var ref_name: String = OS.get_environment("LA_PASS_PROBE_REF")
	var ref: PackedFloat32Array = _f._gpu.read_raw(ref_name) if ref_name != "" else PackedFloat32Array()
	# `LA_PASS_PROBE_OPEN=1`: only open cells compete for the peak.
	var open_only: bool = OS.get_environment("LA_PASS_PROBE_OPEN") != ""
	var sol: PackedFloat32Array = _f._gpu.read_raw("solid") if open_only else PackedFloat32Array()
	for i in (one.size() if pin == "" else 0):
		if open_only and sol.size() > i and sol[i] != 0.0:
			continue
		var a: float = absf(one[i])
		if ref.size() == one.size():
			a = absf(one[i] - ref[i]) / absf(ref[i]) if ref[i] != 0.0 else 0.0
		if a > top or (is_nan(one[i]) and not is_nan(top)):
			top = a if is_finite(a) else NAN
			at = i
	var out: Dictionary = {"idx": at, "v": String.num(one[at])}
	if ref.size() > at:
		out["ref"] = String.num(ref[at])
	var nans: Dictionary = {}
	for name in ["rho_bulk", "mom_x", "mom_y", "mom_z", "vel_x", "vel_y", "vel_z", "speed", "mach", "pressure", "h2o",
			"e_j_m3", "e_lith_j_m3", "solid", "temp", "temp_lith", "o2", "n2", "co2", "silicate", "h_sensible", "cap_sensible",
			"gas_r", "gas_gamma", "cell_edge", "lithic_kg", "k_cond", "regolith", "porosity", "h2o_pore", "h2o_liquid", "h2o_vapour", "lattice_frac", "h_h2o", "h_h2o_vap", "cement",
			"h2", "co", "so2", "h2s", "ch4", "biomass", "detritus", "fuel", "fungus", "fert", "carbonate", "silica", "metal", "olivine", "pyroxene", "plagioclase", "halite", "apatite", "p_fluid", "conductivity"]:
		var b: PackedFloat32Array = _f._gpu.read_raw(String(name))
		if b.size() != _f._cell_count:
			continue
		out[name] = String.num(b[at])
		var n: int = 0
		for x in b:
			if not is_finite(x):
				n += 1
		if n > 0:
			nans[name] = n
	out["nans"] = nans
	var lv: PackedByteArray = _f._gpu.read_raw_bytes("tlevel")
	if lv.size() >= (at + 1) * 4:
		out["tlevel"] = lv.decode_s32(at * 4)
	# The CPU-side seed arrays the device was handed, for the same cell.
	for name in ["_surface_depth", "_rock_fraction", "_water_fraction"]:
		var arr = _f.get(name)
		if arr is PackedFloat32Array and arr.size() > at:
			out["cpu" + name] = String.num(arr[at])
	if _f._mirrors != null and _f._mirrors.has("porosity"):
		out["cpu_porosity"] = String.num(_f._mirrors.at("porosity", at))
	if _f._regolith.size() > at:
		out["cpu_regolith"] = _f._regolith[at]
	var g: PackedFloat32Array = _f._gpu.read_raw("g_rest")
	if g.size() >= (at + 1) * 3:
		out["g"] = [String.num(g[at * 3]), String.num(g[at * 3 + 1]), String.num(g[at * 3 + 2])]
	var pos: PackedFloat32Array = _f._gpu.read_raw("pos")
	if pos.size() >= (at + 1) * 3:
		out["pos"] = [String.num(pos[at * 3]), String.num(pos[at * 3 + 1]), String.num(pos[at * 3 + 2])]
	out["faces"] = _faces(at)
	var depth: String = OS.get_environment("LA_PASS_PROBE_COLUMN")
	if depth != "":
		out["column"] = _column(at, int(depth))
	return out


## The cells under `at`, following each cell's own down slot, with the state that decides the face.
func _column(at: int, depth: int) -> Array:
	var off: PackedByteArray = _f._gpu.read_raw_bytes("slot_off")
	var nbr: PackedByteArray = _f._gpu.read_raw_bytes("nbr")
	var g: PackedFloat32Array = _f._gpu.read_raw("g_rest")
	var sol: PackedFloat32Array = _f._gpu.read_raw("solid")
	var rows: Array = []
	var cols: Dictionary = {}
	for name in ["rho_bulk", "pressure", "temp", "vel_x", "vel_y", "vel_z", "mach", "cell_edge", "n2", "h2o", "lithic_kg", "e_j_m3"]:
		cols[name] = _f._gpu.read_raw(String(name))
	var c: int = at
	for i in depth:
		if c < 0 or g.size() < (c + 1) * 3 or off.size() < (c + 1) * 28:
			break
		var gv: Vector3 = Vector3(g[c * 3], g[c * 3 + 1], g[c * 3 + 2])
		var axis: int = gv.abs().max_axis_index()
		var d: int = axis * 2 + (1 if gv[axis] > 0.0 else 0)
		var lo: int = off.decode_u32((c * 7 + d) * 4)
		var hi: int = off.decode_u32((c * 7 + d + 1) * 4)
		var n: int = -1
		if hi > lo and nbr.size() >= (lo + 1) * 4:
			n = nbr.decode_s32(lo * 4)
		var row: Dictionary = {"c": c, "down": n, "faces": hi - lo, "solid": String.num(sol[c]) if sol.size() > c else ""}
		for name in cols:
			var b: PackedFloat32Array = cols[name]
			if b.size() > c:
				row[name] = String.num(b[c])
		rows.append(row)
		c = n
	return rows


## Every face of the cell: slot, neighbour index and the neighbour's state that decides the face.
func _faces(at: int) -> Array:
	var off: PackedByteArray = _f._gpu.read_raw_bytes("slot_off")
	var nbr: PackedByteArray = _f._gpu.read_raw_bytes("nbr")
	var rows: Array = []
	if off.size() < (at + 1) * 28:
		return rows
	var cols: Dictionary = {}
	for name in ["rho_bulk", "pressure", "temp", "solid", "vel_x", "vel_y", "vel_z", "mach", "gas_r", "cell_edge", "n2", "h2o"]:
		cols[name] = _f._gpu.read_raw(String(name))
	var lv: PackedByteArray = _f._gpu.read_raw_bytes("tlevel")
	for d in 6:
		var lo: int = off.decode_u32((at * 7 + d) * 4)
		var hi: int = off.decode_u32((at * 7 + d + 1) * 4)
		for f in range(lo, hi):
			var n: int = nbr.decode_s32(f * 4) if nbr.size() >= (f + 1) * 4 else -9
			var row: Dictionary = {"slot": d, "n": n}
			if n >= 0:
				for name in cols:
					var b: PackedFloat32Array = cols[name]
					if b.size() > n:
						row[name] = String.num(b[n])
				if lv.size() >= (n + 1) * 4:
					row["tlevel"] = lv.decode_s32(n * 4)
			rows.append(row)
	return rows


## Mask-free matter in the channel, right now.
func _total() -> float:
	var gpu = _f._gpu
	var cc: int = _f._cell_count
	var vol: PackedFloat32Array = _f._grid.cell_volumes() if _f._grid != null else PackedFloat32Array()
	if gpu == null or vol.size() < cc:
		return NAN
	var one: PackedFloat32Array = gpu.read_raw(_channel)
	if one.size() != cc:
		return NAN
	return LAGridGeometry.weighted(one, vol, PackedByteArray(), false)
