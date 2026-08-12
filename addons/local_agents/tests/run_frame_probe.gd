@tool
extends SceneTree


const MARKER: String = "FRAME_PROBE"
const GROUP_LATE: StringName = &"la_frame_probe_late"
const GROUP_EXISTING: StringName = &"la_frame_probe_existing"
const CREATURE_GROUP: StringName = &"la_creatures"


## Mirrors the ordering hazard exactly: set_cognition_scheduler() does nothing until setup() has built
## the cognition object, which is what made synchronous adoption a silent no-op.
class LateCreatureStandIn extends Node:
	var adopted: Object = null
	var _cognition: RefCounted = null

	func set_cognition_scheduler(scheduler: Object) -> void:
		if _cognition != null:
			adopted = scheduler

	func setup() -> void:
		_cognition = RefCounted.new()


var _failures: Array[String] = []
var _notes: Dictionary = {}


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	await _probe_existing_member()
	await _probe_late_member()
	await _probe_real_creatures()
	await _probe_physics_frames()
	var payload: Dictionary = {
		"ok": _failures.is_empty(),
		"failures": _failures,
		"notes": _notes,
	}
	print("%s=%s" % [MARKER, JSON.stringify(payload, "", false)])
	quit(0 if _failures.is_empty() else 1)


# 1. Already in the group before the scheduler exists: adopted by _adopt_existing on ready.
func _probe_existing_member() -> void:
	var member: LateCreatureStandIn = LateCreatureStandIn.new()
	member.name = "ExistingMember"
	member.setup()
	root.add_child(member)
	member.add_to_group(GROUP_EXISTING)

	var scheduler: LocalAgentCognitionScheduler = LocalAgentCognitionScheduler.new()
	scheduler.name = "ExistingScheduler"
	scheduler.adopt_group = GROUP_EXISTING
	root.add_child(scheduler)
	await process_frame

	if member.adopted != scheduler:
		_fail("A node already in adopt_group was not adopted when the scheduler entered the tree.")
	_notes["existing_adopted"] = member.adopted == scheduler

	root.remove_child(scheduler)
	scheduler.free()
	root.remove_child(member)
	member.free()


# 2. THE regression: added to the group after add_child, configured after that again.
func _probe_late_member() -> void:
	var scheduler: LocalAgentCognitionScheduler = LocalAgentCognitionScheduler.new()
	scheduler.name = "LateScheduler"
	scheduler.adopt_group = GROUP_LATE
	root.add_child(scheduler)
	await process_frame

	var member: LateCreatureStandIn = LateCreatureStandIn.new()
	member.name = "LateMember"
	root.add_child(member)              # node_added fires HERE, before the group and before setup()
	member.add_to_group(GROUP_LATE)
	member.setup()

	var adopted_synchronously: bool = member.adopted != null
	if adopted_synchronously:
		_fail("Adoption happened synchronously inside add_child. It must be deferred: a creature's cognition does not exist yet at that point, so the call is a silent no-op.")
	await process_frame
	if member.adopted != scheduler:
		_fail("A node added to adopt_group after add_child was never adopted, even after a frame.")
	_notes["late_sync_adopted"] = adopted_synchronously
	_notes["late_deferred_adopted"] = member.adopted == scheduler

	root.remove_child(member)
	member.free()
	root.remove_child(scheduler)
	scheduler.free()


# 3. The same ordering with real Creature nodes produced by a real spawner.
func _probe_real_creatures() -> void:
	var scheduler: LocalAgentCognitionScheduler = LocalAgentCognitionScheduler.new()
	scheduler.name = "CreatureScheduler"
	scheduler.adopt_group = CREATURE_GROUP
	root.add_child(scheduler)
	await process_frame

	var spawner: LocalAgentCreatureSpawner = LocalAgentCreatureSpawner.new()
	spawner.name = "ProbeSpawner"
	spawner.build_floor = false
	spawner.spawn_on_ready = false
	spawner.ground_y = 0.0
	spawner.placement_seed = 3
	var wanted: Dictionary[String, int] = {"rabbit": 2}
	spawner.counts = wanted
	root.add_child(spawner)
	spawner.spawn()

	var made: Array[Node] = spawner.spawned()
	if made.size() != 2:
		_fail("The spawner made %d creatures in the frame probe, expected 2." % made.size())
	await process_frame

	var adopted: int = 0
	for creature in made:
		if not creature.has_method("get_cognition"):
			_fail("A spawned creature exposes no get_cognition(); the probe cannot observe adoption.")
			break
		var cognition: Object = creature.call("get_cognition")
		if cognition == null:
			_fail("A spawned creature has no cognition object, so no scheduler could ever be attached.")
			continue
		if cognition.call("scheduler") == scheduler:
			adopted += 1
	if adopted != made.size():
		_fail("%d of %d real creatures were adopted by the scheduler through the la_creatures group." % [adopted, made.size()])
	_notes["creatures_adopted"] = adopted
	_notes["creatures_spawned"] = made.size()

	spawner.clear()
	root.remove_child(spawner)
	spawner.free()
	root.remove_child(scheduler)
	scheduler.free()


# 4. Real physics frames actually reach an in-tree harness. The counter starts on the frame after it
# is added, so one frame of slack is allowed - the point is that it tracks physics, not that it is
# phase-locked to the moment of insertion.
func _probe_physics_frames() -> void:
	var host: Node = Node.new()
	host.name = "ProbeHarnessHost"
	root.add_child(host)
	var harness: LocalAgentDemoHarness = LocalAgentDemoHarness.new()
	harness.report_source = host
	host.add_child(harness)
	harness.run_frames = 1000000        # armed but never reached, so it never quits this process
	harness.shoot_path = ""

	var physics_before: int = Engine.get_physics_frames()
	for i in range(5):
		await physics_frame
	var elapsed: int = Engine.get_physics_frames() - physics_before
	var counted: int = harness.frames_elapsed()
	if counted <= 0:
		_fail("The harness counted no physics frames at all over %d engine physics frames." % elapsed)
	elif absi(counted - elapsed) > 1:
		_fail("The harness counted %d frames over %d engine physics frames." % [counted, elapsed])
	_notes["physics_counted"] = counted
	_notes["physics_elapsed"] = elapsed

	root.remove_child(host)
	host.free()


func _fail(message: String) -> void:
	if not _failures.has(message):
		_failures.append(message)
