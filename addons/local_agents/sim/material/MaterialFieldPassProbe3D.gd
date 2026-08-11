class_name LAMaterialFieldPassProbe3D
extends RefCounted

## Totals ONE channel after EVERY pass, for the first few steps. `LA_PASS_PROBE=o2`.
##
## The mineral and energy probes each named their culprit in a single run, but each is bespoke to its own
## ledger. This one takes a channel name, so any runaway can be attributed without writing a new probe.

const DEFAULT_STEPS: int = 3

var _f = null
var _channel: String = ""
var _steps: int = DEFAULT_STEPS
var _step: int = 0
var _prev: float = NAN


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
		_prev = NAN


func _on_pass(pass_index: int, pass_name: String) -> void:
	var total: float = _total()
	if is_nan(total):
		return
	var delta: float = 0.0 if is_nan(_prev) else total - _prev
	_prev = total
	print("PASS_PROBE=", JSON.stringify({
		"step": _step, "pass": pass_name if pass_index >= 0 else "start",
		"channel": _channel, "total": total, "delta": delta}))


func _total() -> float:
	var gpu = _f._gpu
	if gpu == null or not gpu.has_method("channel_total_now"):
		return NAN
	return gpu.channel_total_now(_channel)
