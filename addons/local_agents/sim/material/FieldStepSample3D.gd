class_name LAFieldStepSample3D
extends RefCounted

## The between-pass sampling seam: which field steps are checkpointed, what step the driver is on, how a
## pass is labelled, and how one sampled step is published.

## Field steps between sampled PAIRS. A sample checkpoints between every pass, so it is not free.
const SAMPLE_EVERY: int = 50

var _f = null
var _every: int = SAMPLE_EVERY
# Primed so the first pair samples at field step 1: the opening total is what separates a run that lost
# matter from a build that started with less.
var _gate: int = SAMPLE_EVERY - 1
var _in_pair: int = 0                      # 0 = not sampling, 1 = first of the pair, 2 = second


func setup(field, every: int = SAMPLE_EVERY) -> void:
	_f = field
	_every = maxi(1, every)
	_gate = _every - 1


## 0 = not sampling, 1 = first of the pair, 2 = second.
func pair() -> int:
	return _in_pair


## Advances the pair state machine and arms `probe` between passes on the sampled steps, leaving the
## driver's one slot empty otherwise. True when this step OPENS a pair.
func arm(probe: Callable) -> bool:
	if _f == null or _f._gpu == null or not _f._gpu.has_method("set_step_probe"):
		return false
	var opened: bool = false
	if _in_pair == 1:
		_in_pair = 2
	else:
		_gate += 1
		if _gate >= _every:
			_gate = 0
			_in_pair = 1
			opened = true
		else:
			_in_pair = 0
	if _in_pair == 0:
		_f._gpu.set_step_probe(Callable())
		return false
	_f._gpu.set_step_probe(probe)
	return opened


## Print one sampled step under `marker`, headed by the step and which half of the pair it is.
func publish(marker: String, body: Dictionary) -> void:
	var out: Dictionary = {"field_step": field_step(_f), "pair": _in_pair}
	out.merge(body)
	print(marker, "=", JSON.stringify(out))


## The driver's field step. -1 with no device.
static func field_step(field) -> int:
	if field == null or field._gpu == null:
		return -1
	return int(field._gpu._step_index)


## Short leg label: "WaterSlumpLavaPass" -> "water_slump_lava".
static func leg_key(pass_name: String) -> String:
	var s: String = pass_name
	if s.ends_with("Pass"):
		s = s.substr(0, s.length() - 4)
	return s.to_snake_case()
