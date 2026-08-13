class_name LASimLoop
extends Node

## THE SIMULATION'S LOOP. Simulated time is the step count; nothing here reads a frame delta.

## Fires per engine tick while a holder is seeding. No simulated time passes.
signal seeding(tick: int)
## Fires steps_per_tick times per engine tick once every holder has released.
signal stepped(step: int)

const STEPS_PER_TICK_MAX: int = 8

static var _active: LASimLoop = null

var _step: int = 0
var _tick: int = 0
var _holds: int = 0
var _steps_per_tick: int = 1


static func active() -> LASimLoop:
	return _active


## Steps taken since the world was sealed, or 0 when no world is running.
static func step_count() -> int:
	return _active._step if _active != null else 0


func _ready() -> void:
	_active = self


func _exit_tree() -> void:
	if _active == self:
		_active = null


## Simulated seconds one step represents.
static func step_seconds() -> float:
	return LAMaterialFieldSphereStep3D.SIM_SECONDS_PER_STEP


## Simulated seconds since the world was sealed.
func elapsed_s() -> float:
	return float(_step) * step_seconds()


func step_index() -> int:
	return _step


## Hold the loop in the SEEDING phase. Every holder must release before simulated time starts.
func hold() -> void:
	_holds += 1


func release() -> void:
	_holds = maxi(0, _holds - 1)


func is_seeding() -> bool:
	return _holds > 0


## Steps run per engine tick. A user-facing fast-forward: it buys steps, never a larger timestep.
func set_steps_per_tick(n: int) -> void:
	_steps_per_tick = clampi(n, 1, STEPS_PER_TICK_MAX)


func steps_per_tick() -> int:
	return _steps_per_tick


## Restore the step count from a save. Simulated seconds are the serialised form.
func restore_elapsed_s(seconds: float) -> void:
	_step = int(maxf(0.0, seconds) / step_seconds())


func _physics_process(_delta: float) -> void:
	if _holds > 0:
		_tick += 1
		seeding.emit(_tick)
		return
	for _i in _steps_per_tick:
		_step += 1
		# Published BEFORE the step runs: a module sampling mid-step reads the time of the step it is in.
		LASimReport.gauge("sim_steps", float(_step))
		LASimReport.gauge("field_sim_s", elapsed_s())
		stepped.emit(_step)
