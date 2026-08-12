@tool
extends RefCounted


const SvcScript: GDScript = preload("res://addons/local_agents/graph/BackstoryGraphService.gd")
const ChronicleScript: GDScript = preload("res://addons/local_agents/sim/ecology/BandChronicle.gd")
const ClockScript: GDScript = preload("res://addons/local_agents/sim/SimClock.gd")
const ExtensionLoader: GDScript = preload("res://addons/local_agents/runtime/LocalAgentExtensionLoader.gd")

const DB_PATH: String = "user://local_agents/test_band_affiliation.sqlite3"
const SPECIES: String = "testbeast"
const FLOCK_RADIUS: float = 10.0
const STEP: float = LACreatureAffiliation.ASSOC_PERIOD

## Day the first band settles on, and the day the wanderer switches. Different so a closed record has a
## from_day and a to_day that can be told apart.
const DAY_FIRST: int = 0
const DAY_SWITCH: int = 5


## The duck-typed surface LACreatureAffiliation and LABandChronicle read, and nothing else.
class Beast extends Node3D:
	var species: String = SPECIES
	var flock_radius: float = FLOCK_RADIUS
	var band_id: int = 0
	var _band_solo: int = 0
	var _assoc: Dictionary = {}
	var _assoc_cd: float = 0.0
	var _carcass: bool = false
	var _dead: bool = false
	var _held: bool = false
	var _dying: bool = false


func run_test(tree: SceneTree) -> bool:
	if not ExtensionLoader.ensure_initialized():
		push_error("NetworkGraph init failed: %s" % ExtensionLoader.get_error())
		return false
	if not ClassDB.class_exists("NetworkGraph"):
		push_error("NetworkGraph class missing after extension init.")
		return false

	# Set the path BEFORE the service enters the tree: _ready() is what opens the handle, and a late path
	# used to be silently dropped, which once had a test wiping the player's real store while reporting PASS.
	var svc: Node = SvcScript.new()
	svc.set_database_path(DB_PATH)
	tree.get_root().add_child(svc)
	svc.clear_backstory_space()

	var clock: LASimClock = ClockScript.new()
	tree.get_root().add_child(clock)
	clock.restore({"elapsed": float(DAY_FIRST) * LASimClock.DAY_LENGTH})

	var chronicle: LABandChronicle = ChronicleScript.new()
	chronicle.set_service(svc)
	tree.get_root().add_child(chronicle)

	var host_a: Beast = _spawn(tree, Vector3(300.0, 0.0, 0.0))
	var host_b: Beast = _spawn(tree, Vector3(302.0, 0.0, 0.0))
	var wanderer: Beast = _spawn(tree, Vector3(0.0, 0.0, 0.0))
	var home_mate: Beast = _spawn(tree, Vector3(2.0, 0.0, 0.0))
	var herd: Array = [host_a, host_b, wanderer, home_mate]

	_run(herd, chronicle, 12)
	var ok: bool = true
	var home_band: int = wanderer.band_id
	ok = _assert(home_band == home_mate.band_id,
		"the wanderer and its home-mate never converged on one band (%d vs %d)" % [home_band, home_mate.band_id]) and ok
	var host_band: int = host_a.band_id
	ok = _assert(host_band == host_b.band_id,
		"the host pair never converged on one band (%d vs %d)" % [host_band, host_b.band_id]) and ok
	ok = _assert(home_band != host_band, "both pairs collapsed into the same band despite being 300 units apart") and ok

	var npc_id: String = "%s_%d" % [SPECIES, wanderer.get_instance_id()]
	var left_faction: String = "band_%d" % home_band
	var joined_faction: String = "band_%d" % host_band

	clock.restore({"elapsed": float(DAY_SWITCH) * LASimClock.DAY_LENGTH})
	wanderer.global_position = Vector3(301.0, 0.0, 2.0)
	_run(herd, chronicle, 40)
	chronicle.flush()

	# The observed change itself: the rule moved it, on its own, from one existing band to the other.
	ok = _assert(wanderer.band_id == host_band,
		"the wanderer never joined the band it moved in with (band %d, expected %d)" % [wanderer.band_id, host_band]) and ok

	var history: Dictionary = svc.membership_history(npc_id)
	var records: Array = history.get("memberships", [])
	ok = _assert(records.size() == 2,
		"expected two dated MEMBER_OF records for a creature that left one group and joined another, got %d: %s" % [records.size(), records]) and ok
	if records.size() != 2:
		return _finish(ok, svc, chronicle, clock, herd, tree)

	# membership_history sorts newest from_day first, so [1] is the membership it LEFT.
	var joined: Dictionary = records[0]
	var left: Dictionary = records[1]
	ok = _assert(String(left.get("faction_id", "")) == left_faction,
		"the older record names %s, not the band it left (%s)" % [left.get("faction_id", ""), left_faction]) and ok
	ok = _assert(String(joined.get("faction_id", "")) == joined_faction,
		"the newer record names %s, not the band it joined (%s)" % [joined.get("faction_id", ""), joined_faction]) and ok
	# The whole point of a dated record: the first one ENDED.
	ok = _assert(int(left.get("to_day", -1)) >= 0,
		"the membership it left was never closed (to_day is %d)" % int(left.get("to_day", -1))) and ok
	ok = _assert(int(left.get("to_day", -1)) >= int(left.get("from_day", -1)),
		"the closed membership ends before it began (from_day %d, to_day %d)" % [int(left.get("from_day", -1)), int(left.get("to_day", -1))]) and ok
	ok = _assert(int(joined.get("to_day", 0)) == -1,
		"the membership it joined is already closed (to_day %d)" % int(joined.get("to_day", 0))) and ok
	ok = _assert(int(joined.get("from_day", -1)) == DAY_SWITCH,
		"the new membership is dated day %d, not the day it actually switched (%d)" % [int(joined.get("from_day", -1)), DAY_SWITCH]) and ok

	# The group it left still exists. A band is not the animals currently standing in it.
	var old_group: Dictionary = svc.get_faction(left_faction)
	ok = _assert(bool(old_group.get("ok", false)) and String((old_group.get("faction", {}) as Dictionary).get("id", "")) == left_faction,
		"the band it left no longer exists in the store: %s" % old_group) and ok

	var context: Dictionary = svc.get_backstory_context(npc_id, DAY_SWITCH + 1, 32)
	var active: Array = []
	for rel_v in (context.get("relationships", []) as Array):
		var rel: Dictionary = rel_v
		if String(rel.get("relationship_type", "")) == "MEMBER_OF":
			active.append(String(rel.get("target_id", "")))
	ok = _assert(active.size() == 1 and active[0] == joined_faction,
		"the day-windowed context should show exactly one live membership (%s), it showed %s" % [joined_faction, active]) and ok

	return _finish(ok, svc, chronicle, clock, herd, tree)


func _run(herd: Array, chronicle: LABandChronicle, steps: int) -> void:
	for i in range(steps):
		LACreatureSenses._index = null
		for b in herd:
			var beast: Beast = b
			LACreatureAffiliation.tick(beast, beast.global_position, STEP)
		chronicle.step(STEP)


func _spawn(tree: SceneTree, at: Vector3) -> Beast:
	var b: Beast = Beast.new()
	tree.get_root().add_child(b)
	b.global_position = at
	b.add_to_group("creature")
	b.add_to_group("species_" + SPECIES)
	LACreatureAffiliation.setup(b)
	b._assoc_cd = 0.0        # no stagger, so the steps below are deterministic
	return b


func _finish(ok: bool, svc: Node, chronicle: Node, clock: Node, herd: Array, tree: SceneTree) -> bool:
	svc.clear_backstory_space()
	for b in herd:
		(b as Node).queue_free()
	chronicle.queue_free()
	clock.queue_free()
	svc.queue_free()
	if FileAccess.file_exists(DB_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(DB_PATH))
	if ok:
		print("Band affiliation test passed (a creature left one band, joined another, and the store kept both dated)")
	return ok


func _assert(condition: bool, message: String) -> bool:
	if not condition:
		push_error(message)
	return condition
