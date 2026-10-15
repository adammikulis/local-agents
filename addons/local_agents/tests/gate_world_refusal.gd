extends SceneTree

## A PIECE THE DEVICE REFUSES INSIDE A WORLD ENDS THE RUN AT THE STEP IT FELL IN. The world plans against
## a wait no piece fits in from before its seed (`--refuse=seed`), or once REFUSE_AFTER steps are
## committed (`--refuse=step`). What the refusal left behind is read here, in the process that ran it.

const QuietWindow: GDScript = preload("res://addons/local_agents/runtime/QuietWindow.gd")
const WORLD: String = "res://addons/local_agents/game/VoxelWorld.tscn"
const ARG: String = "--refuse="
## Microseconds: under any piece's latency floor, so the first piece whose cost is known is refused.
const TINY_WAIT_USEC: float = 1.0
## Steps the step arm commits against its device's own wait before it plans against the tiny one.
const REFUSE_AFTER: int = 1
## LAFieldStateCache's own directory, so a bake this run wrote can be taken back out.
const STATE_DIR: String = "la_field_cache"

var _arm: String = ""
## The world, loaded once the autoloads it names exist: it is never named here as a type.
var _world: Node = null
var _field = null
var _loop: LASimLoop = null
var _seal_key: String = ""
var _seen: PackedInt32Array = PackedInt32Array()
var _armed_at: int = -1
var _full_at_arming: int = -1
var _said: bool = false


func _initialize() -> void:
	QuietWindow.apply_if_automated()
	for a in OS.get_cmdline_user_args():
		if String(a).begins_with(ARG):
			_arm = String(a).substr(ARG.length())
	if _arm != "seed" and _arm != "step":
		print("WORLD_REFUSAL=" + JSON.stringify({"error": "no %sseed or %sstep" % [ARG, ARG]}))
		LocalAgentDemoHarness.print_complete(2)
		quit(2)
		return
	OS.unset_environment("LA_SEAL_RESEED")
	OS.unset_environment("LA_SEAL_KEY")
	if _arm == "seed":
		# A bake no other run names, so an entry under it can only be this run's.
		_seal_key = "gate_world_refusal_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
		OS.set_environment("LA_SEAL_KEY", _seal_key)
		LAFieldDriver.rig_wait_usec(TINY_WAIT_USEC)
	_world = (load(WORLD) as PackedScene).instantiate()
	_world.ready.connect(_attach)
	root.add_child(_world)


## Once the world has wired its loop: subscribed after every subscriber it holds, so this runs on a step
## only once all of them have.
func _attach() -> void:
	_field = _world.get("_material")
	_loop = LASimLoop.active()
	_loop.subscribe(func(step: int) -> void: _seen.append(step))


func _physics_process(_delta: float) -> bool:
	if _said or _loop == null:
		return false
	if _loop.failure != "":
		_verdict()
		return false
	if _arm == "step" and _armed_at < 0 and _loop.step_index() >= REFUSE_AFTER:
		_armed_at = _loop.step_index()
		_full_at_arming = _field.step_driver().full_steps()
		LAFieldDriver.rig_wait_usec(TINY_WAIT_USEC)
	return false


## Printed on the frame after the refusal, before the harness reports the run and quits.
func _verdict() -> void:
	_said = true
	var failed: int = _loop.failed_step
	var committed: int = _loop.step_index()
	var snap: Dictionary = LASimReport.snapshot()
	var clock: LASimClock = LASimClock.active()
	var gravity = _field._gravity._pass if _field._gravity != null else null
	var out: Dictionary = {
		"arm": _arm, "failed": failed, "committed": committed, "armed_at": _armed_at,
		"seen": Array(_seen), "reason": _loop.failure,
		"refused": int(_field._gpu._driver.ledger()["refused"]),
		"sim_steps": int(snap.get("sim_steps", -1)),
		"field_steps": int((snap["events"] as Dictionary).get("field_step", 0)),
		"clock_steps": clock.steps() if clock != null else -1,
		"reduce_rows": _field._queries.reduced().size(),
		"poisson_solves": gravity._solves if gravity != null else 0,
		"full_steps": _field.step_driver().full_steps(), "full_at_arming": _full_at_arming,
		"baked": _take_bake()}
	print("WORLD_REFUSAL=" + JSON.stringify(out))


## Whether this run baked its seed under its own key, and the bake taken back out if it did.
func _take_bake() -> bool:
	if _seal_key == "":
		return false
	var g: LAVoxelGrid = _field._grid
	var k: String = LAFieldStateCache.state_key(_seal_key, g.nx, g.ny, g.nz, g.cell_size, g.origin)
	if LAFieldStateCache.load_blob(k).is_empty():
		return false
	DirAccess.remove_absolute(OS.get_user_data_dir().path_join(STATE_DIR).path_join(k + ".bin"))
	if not LAFieldStateCache.load_blob(k).is_empty():
		push_error("gate_world_refusal: the bake under %s is still in the cache." % k)
	return true
