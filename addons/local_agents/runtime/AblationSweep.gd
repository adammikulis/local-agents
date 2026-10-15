class_name LAAblationSweep
extends Node

## Every LAAblate switch thrown in turn for `frames_per_stage` render frames, after a baseline with all
## on: a physics process and a presentation module are measured switched off, a stand-in in each of its
## three states. Prints ABLATION={...} per stage and ABLATION_SWEEP=[...] at the end, then quits.

var _sim = null
var _frames_per_stage: int = 0
var _stage: int = -1                     # -1 baseline, then an index into _stages
var _stages: Array = []                  # {name, state}: state empty for an on/off switch
var _frames: int = 0
var _sum_us: int = 0
var _max_us: int = 0
var _slow: int = 0
var _last_us: int = 0
var _rows: Array = []
var _started: bool = false


func _init(sim, frames_per_stage: int) -> void:
	_sim = sim
	_frames_per_stage = maxi(frames_per_stage, 10)
	process_mode = Node.PROCESS_MODE_ALWAYS


## One stage per on/off switch, three per stand-in.
func _plan() -> Array:
	var out: Array = []
	LAFakes.states()                                     # the stand-ins take their place on the registry
	for name in LAAblate.names():
		var default_state: String = LAAblate.default_state(String(name))
		if default_state == "":
			out.append({"name": String(name), "state": ""})
			continue
		for state in [LAAblate.state_off(), LAAblate.state_fake(), LAAblate.state_real()]:
			out.append({"name": String(name), "state": state})
	return out


func _apply(stage: Dictionary) -> void:
	var name: String = String(stage["name"])
	if String(stage["state"]) == "":
		LAAblate.set_on(name, false)
		return
	LAAblate.set_state(name, String(stage["state"]))


func _restore(stage: Dictionary) -> void:
	var name: String = String(stage["name"])
	if String(stage["state"]) == "":
		LAAblate.set_on(name, true)
		return
	LAAblate.set_state(name, LAAblate.default_state(name))


func _process(_delta: float) -> void:
	if not _started:
		if _sim == null or not _sim.is_spawned():
			return
		_started = true
		_stages = _plan()
		_last_us = Time.get_ticks_usec()
		return
	var now: int = Time.get_ticks_usec()
	var gap: int = now - _last_us
	_last_us = now
	_frames += 1
	_sum_us += gap
	_max_us = maxi(_max_us, gap)
	if gap > 100000:
		_slow += 1
	if _frames < _frames_per_stage:
		return
	_close_stage()
	_stage += 1
	if _stage >= _stages.size():
		print("ABLATION_SWEEP=", JSON.stringify(_rows))
		set_process(false)
		LAAppQuit.request(self, 0)
		return
	_apply(_stages[_stage])
	_frames = 0
	_sum_us = 0
	_max_us = 0
	_slow = 0


func _close_stage() -> void:
	var name: String = "baseline" if _stage < 0 else String(_stages[_stage]["name"])
	var state: String = "" if _stage < 0 else String(_stages[_stage]["state"])
	var row: Dictionary = {"off": name, "state": state,
		"kind": "" if _stage < 0 else LAAblate.kind_of(name),
		"frames": _frames, "mean_ms": float(_sum_us) / float(maxi(_frames, 1)) / 1000.0,
		"max_ms": float(_max_us) / 1000.0, "slow_frames": _slow}
	_rows.append(row)
	print("ABLATION=", JSON.stringify(row))
	if _stage >= 0:
		_restore(_stages[_stage])
