class_name LAAblationSweep
extends Node

## Every LAAblate switch off in turn for `frames_per_stage` render frames, after a baseline with all on:
## a physics process the rung contains and a presentation module are measured the same way.
## Prints ABLATION={...} per stage and ABLATION_SWEEP=[...] at the end, then quits.

var _sim = null
var _frames_per_stage: int = 0
var _stage: int = -1                     # -1 baseline, then an index into _names
var _names: PackedStringArray = PackedStringArray()
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


func _process(_delta: float) -> void:
	if not _started:
		if _sim == null or not _sim.is_spawned():
			return
		_started = true
		_names = LAAblate.names()
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
	if _stage >= _names.size():
		print("ABLATION_SWEEP=", JSON.stringify(_rows))
		set_process(false)
		LAAppExit.request(self, 0)
		return
	LAAblate.set_on(_names[_stage], false)
	_frames = 0
	_sum_us = 0
	_max_us = 0
	_slow = 0


func _close_stage() -> void:
	var name: String = "baseline" if _stage < 0 else _names[_stage]
	var row: Dictionary = {"off": name, "kind": "" if _stage < 0 else LAAblate.kind_of(name),
		"frames": _frames, "mean_ms": float(_sum_us) / float(maxi(_frames, 1)) / 1000.0,
		"max_ms": float(_max_us) / 1000.0, "slow_frames": _slow}
	_rows.append(row)
	print("ABLATION=", JSON.stringify(row))
	if _stage >= 0:
		LAAblate.set_on(_names[_stage], true)
