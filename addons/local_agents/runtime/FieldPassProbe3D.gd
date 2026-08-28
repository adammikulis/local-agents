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


## The cell where |channel| peaks, with the state that decides its dynamics.
func _peak() -> Dictionary:
	var one: PackedFloat32Array = _f._gpu.read_raw(_channel)
	if one.size() != _f._cell_count:
		return {}
	var at: int = 0
	var top: float = 0.0
	for i in one.size():
		var a: float = absf(one[i])
		if a > top or (is_nan(one[i]) and not is_nan(top)):
			top = a if is_finite(a) else NAN
			at = i
	var out: Dictionary = {"idx": at, "v": String.num(one[at])}
	var nans: Dictionary = {}
	for name in ["rho_bulk", "mom_x", "mom_y", "mom_z", "vel_y", "pressure", "celerity", "h2o",
			"h_j_m3", "solid", "temp", "o2", "n2", "co2", "silicate", "h_sensible", "cap_sensible"]:
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
	return out


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
