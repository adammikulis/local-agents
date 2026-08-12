class_name LASimTimeAuthority
extends Node


const SPEEDS: Array[float] = [0.25, 0.5, 1.0, 2.0, 4.0, 8.0]

## Real time, found in the list rather than written down beside it — an index that can disagree with the
## array it indexes is a defect waiting for someone to reorder SPEEDS.
static func play_index() -> int:
	return maxi(SPEEDS.find(1.0), 0)

signal speed_changed(paused: bool, speed: float)

## The live authority, so anything changing speed goes through the node that owns Engine.time_scale.
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


## Set the speed from a raw multiplier, snapped to the nearest supported SPEED. The entry point for every
## non-key speed change (`--fast=N`, the pause menu's speed row, the trailer director).
func set_multiplier(mult: float) -> void:
	var best: int = play_index()
	var best_delta: float = INF
	for i in range(SPEEDS.size()):
		var d: float = absf(SPEEDS[i] - mult)
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


## Back to 1× (Home).
func reset_speed() -> void:
	_idx = play_index()
	_paused = false
	_apply()


func is_paused() -> bool:
	return _paused


## The effective playback rate (0 while paused).
func current_speed() -> float:
	return 0.0 if _paused else SPEEDS[_idx]


func speed_index() -> int:
	return _idx


func _apply() -> void:
	get_tree().paused = _paused
	if not _paused:
		Engine.time_scale = SPEEDS[_idx]
		Engine.max_physics_steps_per_frame = maxi(8, int(ceil(SPEEDS[_idx])) * 8)
	speed_changed.emit(_paused, current_speed())
