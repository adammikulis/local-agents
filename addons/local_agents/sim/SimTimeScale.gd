class_name LASimTimeScale
extends Node

## THE PLAYBACK RATE. One owner of `Engine.time_scale`, `Engine.max_physics_steps_per_frame` and
## `get_tree().paused`.
##
## This is a plain Node, not a widget. It was a CanvasLayer — the on-screen time-control HUD owned the
## simulation's clock — so the rate could not be built without building a panel, a label and a toast, and
## a measurement run therefore either drew UI or ran at the wrong speed. A presentation node may not sit
## on the authoritative path.
##
## PROCESS_MODE_ALWAYS so it keeps running while the tree is paused; that is what lets anything un-pause.
##
## (Explicit types only, no ':=' inferred typing.)

const SPEEDS: Array[float] = [0.25, 0.5, 1.0, 2.0, 4.0, 8.0]


## Real time. Found in SPEEDS rather than written as an index, so reordering the row cannot desync them.
static func play_idx() -> int:
	return SPEEDS.find(1.0)

signal speed_changed(paused: bool, speed: float)

## The live authority, so anything changing speed goes through the node that owns Engine.time_scale rather
## than writing it directly and being silently overwritten by this node's own _ready().
static var _active: LASimTimeScale = null

var _idx: int = SPEEDS.find(1.0)
var _paused: bool = false


func _init() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func _ready() -> void:
	_active = self
	_apply()


func _exit_tree() -> void:
	if _active == self:
		_active = null


static func active() -> LASimTimeScale:
	return _active


## Set the speed from a raw multiplier, snapped to the nearest supported SPEED. The entry point for every
## non-key speed change: `--fast=N`, the pause menu's speed row, the trailer director.
func set_multiplier(mult: float) -> void:
	var best: int = play_idx()
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


func is_paused() -> bool:
	return _paused


## The effective playback rate (0 while paused).
func current_speed() -> float:
	return 0.0 if _paused else SPEEDS[_idx]


func _apply() -> void:
	var tree: SceneTree = get_tree()
	if tree != null:
		tree.paused = _paused
	if not _paused:
		Engine.time_scale = SPEEDS[_idx]
		# Ticks one RENDERED frame may run, scaled by the speed on purpose: time_scale already multiplies
		# each tick's delta, so this buys THROUGHPUT rather than helping physics keep up.
		#
		# Sim-time per rendered frame is therefore QUADRATIC in the multiplier (8*s ticks each carrying
		# s/60 seconds), so `--run-frames=N` is NOT a fixed horizon across multipliers. Place two runs on
		# the same horizon by reading `field_sim_s`, never by frames.
		Engine.max_physics_steps_per_frame = maxi(8, int(ceil(SPEEDS[_idx])) * 8)
	speed_changed.emit(_paused, current_speed())
