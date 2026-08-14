class_name LAMaterialFieldPassProbe3D
extends RefCounted

const CellVolScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldCellVolume3D.gd")

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
	if is_nan(amount):
		return
	print("PASS_PROBE=", JSON.stringify({
		"step": _step, "pass": pass_name if pass_index >= 0 else "start",
		"channel": _channel, "amount": amount}))


## Mask-free matter in the channel, right now.
func _total() -> float:
	var gpu = _f._gpu
	var cc: int = _f._cell_count
	var vol: PackedFloat32Array = CellVolScript.of(_f)
	if gpu == null or vol.size() != cc:
		return NAN
	var one: PackedFloat32Array = gpu.read_raw(_channel)
	if one.size() != cc:
		return NAN
	return CellVolScript.weighted(one, vol, PackedByteArray(), false)
