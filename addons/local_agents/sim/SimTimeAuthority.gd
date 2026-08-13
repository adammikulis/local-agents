class_name LASimTimeAuthority
extends Node


## Playback speed, in SIM STEPS PER ENGINE TICK. Fast-forward buys steps; the timestep never moves.
const SPEEDS: Array[int] = [1, 2, 4, 8]

## Real time, found in the list rather than written down beside it — an index that can disagree with the
## array it indexes is a defect waiting for someone to reorder SPEEDS.
static func play_index() -> int:
	return maxi(SPEEDS.find(1), 0)

signal speed_changed(paused: bool, speed: float)

## The live authority, so anything changing speed goes through the node that owns the loop's step budget.
static var _active: LASimTimeAuthority = null

var _idx: int = play_index()
var _paused: bool = false


func _init() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func _ready() -> void:
	_active = self
	_apply()


func _exit_tree() -> void:
	if _active == self:
		_active = null


static func active() -> LASimTimeAuthority:
	return _active


## Set the speed from a raw steps-per-tick request, snapped to the nearest supported SPEED.
func set_steps_per_tick(n: int) -> void:
	var best: int = play_index()
	var best_delta: int = 1 << 30
	for i in range(SPEEDS.size()):
		var d: int = absi(SPEEDS[i] - n)
		if d < best_delta:
			best_delta = d
			best = i
	_idx = best
	_paused = false
	_apply()


func toggle_pause() -> void:
	_paused = not _paused
	_apply()


func play() -> void:
	_paused = false
	_apply()


func faster() -> void:
	_paused = false
	_idx = mini(_idx + 1, SPEEDS.size() - 1)
	_apply()


func slower() -> void:
	_paused = false
	_idx = maxi(_idx - 1, 0)
	_apply()


## Back to 1 step per tick (Home).
func reset_speed() -> void:
	_idx = play_index()
	_paused = false
	_apply()


func is_paused() -> bool:
	return _paused


## The effective playback rate in steps per tick (0 while paused).
func current_speed() -> float:
	return 0.0 if _paused else float(SPEEDS[_idx])


func speed_index() -> int:
	return _idx


func _apply() -> void:
	get_tree().paused = _paused
	var loop: LASimLoop = LASimLoop.active()
	if not _paused and loop != null:
		loop.set_steps_per_tick(SPEEDS[_idx])
	speed_changed.emit(_paused, current_speed())
