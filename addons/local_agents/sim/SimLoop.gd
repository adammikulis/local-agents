class_name LASimLoop
extends Node

## THE SIMULATION'S LOOP. Simulated time is the step count; nothing here reads a frame delta.

## Fires per engine tick while a holder is seeding. No simulated time passes.
signal seeding

const STEPS_PER_TICK_MAX: int = 8

static var _active: LASimLoop = null

## A step's work, in the order subscribed, steps_per_tick times per engine tick once every holder has
## released. A step is committed when every one of them has run on it.
var _subscribers: Array[Callable] = []
var _step: int = 0
var _holds: int = 0
var _steps_per_tick: int = 1
## Why the run stopped, or "" while it runs. Written by fail() alone.
var failure: String = ""
## The step the run failed in: the one in flight, or the step the world stood at (0 is the seed).
var failed_step: int = -1
var _halt_step: int = -1


static func active() -> LASimLoop:
	return _active


func _enter_tree() -> void:
	_active = self


## The committed step, read when the report is: never a step in flight, and never wiped by a reset.
func _ready() -> void:
	LASimReport.register(func() -> Dictionary: return {"sim_steps": _step, "field_sim_s": elapsed_s()})


func _exit_tree() -> void:
	if _active == self:
		_active = null


## Simulated seconds one step represents.
static func step_seconds() -> float:
	return LAMaterialFieldSphereStep3D.SIM_SECONDS_PER_STEP


## Simulated seconds since the world was sealed.
func elapsed_s() -> float:
	return float(_step) * step_seconds()


## The committed step count; inside a step, the step in flight.
func step_index() -> int:
	return _step


## Run `on_step(step)` on every step, after every subscriber before it.
func subscribe(on_step: Callable) -> void:
	_subscribers.append(on_step)


## END THE RUN. The step in flight is not committed and no subscriber after the caller runs on it. The
## first reason stands.
func fail(reason: String) -> void:
	if failure == "":
		failure = reason
		failed_step = _step


## Hold the loop in the SEEDING phase. Every holder must release before simulated time starts.
func hold() -> void:
	_holds += 1


func release() -> void:
	_holds = maxi(0, _holds - 1)


## Steps run per engine tick. A user-facing fast-forward: it buys steps, never a larger timestep.
func set_steps_per_tick(n: int) -> void:
	_steps_per_tick = clampi(n, 1, STEPS_PER_TICK_MAX)


## Run no step past `step`: the world stands at that simulated time. Negative runs on.
func halt_at(step: int) -> void:
	_halt_step = step


## Restore the step count from a save. Simulated seconds are the serialised form, read back to the
## NEAREST step: truncating biases a restore backwards by a step whenever the division lands just under.
func restore_elapsed_s(seconds: float) -> void:
	_step = roundi(maxf(0.0, seconds) / step_seconds())


func _physics_process(_delta: float) -> void:
	if failure != "":
		return
	if _holds > 0:
		seeding.emit()
		return
	for _i in _steps_per_tick:
		if _halt_step >= 0 and _step >= _halt_step: return
		_step += 1
		# Every subscriber on the step in flight until one fails the run. One subscribed during the step
		# first runs on the next; one whose object is gone is dropped.
		_subscribers = _subscribers.filter(func(s: Callable) -> bool: return s.is_valid())
		for i in _subscribers.size():
			if failure == "" and _subscribers[i].is_valid():
				_subscribers[i].call(_step)
		if failure != "":
			_step -= 1
			return
