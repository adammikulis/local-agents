@tool
extends RefCounted

## Proves an animal can LEAVE one group and JOIN another, and that the world remembers both.
##
## The thing under test is the split of one integer into two. `family_id` used to mean both "who I descend
## from" and "who I run with"; lineage is immutable for life by design, so affiliation inherited an
## immutability it had no business having and nothing could ever change groups. Affiliation now lives in
## `band_id` (LACreatureAffiliation, derived from sustained association) and its history lives in dated
## MEMBER_OF records in the backstory store (LABandChronicle).
##
## WHAT IS ASSERTED, and why it is not the obvious thing. Every assertion below reads state back OUT of the
## store — the membership history, the day-windowed context, the faction node. None of them asserts that a
## call returned ok. The first backstory wiring in this repo returned ok from every single call and recalled
## nothing (see the header of test_agent_backstory.gd), so "it said ok" is worth nothing here.
##
## The rule is driven directly rather than through a launched world, because the question is whether the
## rule produces a membership CHANGE and whether the chronicle writes it down as a period with an end — and
## that is settled by stepping it, in about a second, with no GPU, no terrain and no model. The stubs below
## carry exactly the duck-typed surface LACreatureAffiliation reads, which is also a check that the rule
## really is decoupled from LocalAgentCreature.
## (Explicit types only, project rule: no ':=' inferred typing.)

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

	# The RESIDENTS are built first, so their band label is the older one. Affiliation only ever adopts an
	# older label (that is what makes label propagation converge instead of two animals swapping forever),
	# so building them first is what makes this a wanderer JOINING an established band rather than renaming
	# it — the same asymmetry a real newcomer meets.
	var host_a: Beast = _spawn(tree, Vector3(300.0, 0.0, 0.0))
	var host_b: Beast = _spawn(tree, Vector3(302.0, 0.0, 0.0))
	var wanderer: Beast = _spawn(tree, Vector3(0.0, 0.0, 0.0))
	var home_mate: Beast = _spawn(tree, Vector3(2.0, 0.0, 0.0))
	var herd: Array = [host_a, host_b, wanderer, home_mate]

	# --- Phase 1: two separate pairs keep company until each pair has settled into one band. ---
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

	# --- Phase 2: the wanderer walks over to the other pair. Nothing tells it to change band. ---
	clock.restore({"elapsed": float(DAY_SWITCH) * LASimClock.DAY_LENGTH})
	wanderer.global_position = Vector3(301.0, 0.0, 2.0)
	_run(herd, chronicle, 40)
	chronicle.flush()

	# The observed change itself: the rule moved it, on its own, from one existing band to the other.
	ok = _assert(wanderer.band_id == host_band,
		"the wanderer never joined the band it moved in with (band %d, expected %d)" % [wanderer.band_id, host_band]) and ok

	# --- What the world remembers. Everything below is read back out of the store. ---
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

	# And the day-windowed read the game itself uses agrees: exactly one membership is live, the new one.
	# Asked on the day AFTER the switch, because the store's window treats to_day as INCLUSIVE — a membership
	# that ended on day five was still real for part of day five, and this test reads that convention rather
	# than arguing with it.
	var context: Dictionary = svc.get_backstory_context(npc_id, DAY_SWITCH + 1, 32)
	var active: Array = []
	for rel_v in (context.get("relationships", []) as Array):
		var rel: Dictionary = rel_v
		if String(rel.get("relationship_type", "")) == "MEMBER_OF":
			active.append(String(rel.get("target_id", "")))
	ok = _assert(active.size() == 1 and active[0] == joined_faction,
		"the day-windowed context should show exactly one live membership (%s), it showed %s" % [joined_faction, active]) and ok

	return _finish(ok, svc, chronicle, clock, herd, tree)


## Advance every animal's association rule and the chronicle by `steps` samples of STEP seconds.
##
## The shared spatial index is stamped with the PHYSICS FRAME, and no physics frames pass inside a
## synchronous test, so it would be built once and then hand out positions from before the wanderer moved —
## and the test would pass on stale data. Dropping the static forces a real rebuild per step at the
## positions the animals are actually at.
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
