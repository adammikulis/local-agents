class_name LABandChronicle
extends Node

## Writes the world's SOCIAL HISTORY down: which band each animal belongs to, from which day to which day.
##
## LACreatureAffiliation decides membership from sustained association and keeps it as a cached integer on
## the node, because the flocking and leadership paths read it every frame. That integer is the present
## tense and nothing else — it cannot say when an animal joined, that it once ran with a different band,
## or that the band it left is still out there. This node is the other half: it watches those integers on a
## coarse cadence and turns each settled CHANGE into a dated MEMBER_OF record in the backstory store
## (LocalAgentBackstoryGraphService), which is the shape that can hold a period rather than a flag.
##
## The division is the point. Per frame: one cached integer compare, here and in the creature. Per
## membership EVENT (join, leave, dissolve, die): one bounded set of store writes. The store is never on
## the per-frame path.
##
## SETTLED, not momentary. Label propagation is at its noisiest in the first seconds after a herd spawns,
## and none of that churn is history — it is the rule converging. So a change is only written once the new
## band has been held for DWELL_SECONDS, and a band of ONE is not written at all: an animal on its own is
## unaffiliated, not the sole member of a faction, and recording singletons would fill the store with one
## faction per creature while telling us nothing.
##
## It also owns the world-time record. LASimClock has the day; set_world_time() is how the store learns it.
## (Explicit types only, no ':=' inferred typing.)

const BackstoryServiceScript: GDScript = preload("res://addons/local_agents/graph/BackstoryGraphService.gd")

## Seconds between population scans. The scan is O(population) and reads one integer per creature.
const SCAN_PERIOD: float = 0.5
## How long a new band must hold before it counts as history rather than as the rule still settling.
const DWELL_SECONDS: float = 1.5
## Store writes allowed per scan. SQLite writes are synchronous, so a herd that all changes band at once is
## spread over several scans instead of stalling one frame.
const MAX_WRITES_PER_SCAN: int = 4

var _service: Node = null
var _enabled: bool = false
var _owns_service: bool = false

var _accum: float = 0.0
var _now: float = 0.0                  # chronicle-local seconds, advanced by the scans themselves
var _band_count: int = 0               # distinct multi-member bands at the last scan (telemetry)
var _written: int = 0                  # membership records written this run (telemetry)

# Per-creature bookkeeping, all keyed by instance id.
var _seen: Dictionary = {}             # cid -> the membership last observed (band, or 0 for unaffiliated)
var _since: Dictionary = {}            # cid -> _now when that membership was first observed
var _recorded: Dictionary = {}         # cid -> the band currently written as OPEN in the store (0 = none)
var _npc_ids: Dictionary = {}          # cid -> npc id, kept so a dead creature's record can still be closed
var _pending: Dictionary = {}          # cid -> the band to write next (at most one queued change each)
var _npc_ensured: Dictionary = {}      # cid -> true once upsert_npc has run for it
var _faction_ensured: Dictionary = {}  # band -> true once upsert_faction has run for it


## The chronicle's OWN database, never the shared one. `LocalAgentBackstoryGraphService` defaults to
## `user://local_agents/network.sqlite3`, where a game's conversations and an agent's long memory live; a
## chronicle opening that file would mix throwaway creature rows into the player's actual data.
const CHRONICLE_DB_PATH: String = "user://local_agents/chronicle.sqlite3"


func _ready() -> void:
	if OS.has_environment("LA_NO_CHRONICLE"):
		return
	if _service == null:
		_service = BackstoryServiceScript.new()
		_service.name = "BackstoryGraphService"
		_owns_service = true
		# Path BEFORE add_child: _ready() is what opens the database.
		_service.set_database_path(CHRONICLE_DB_PATH)
		add_child(_service)
		# ONE WORLD'S HISTORY, not every world ever run. npc ids here are derived from Godot instance ids,
		# which are not stable across runs and are actively reused, so last run's rows can never be matched
		# to this run's creatures — keeping them would be an unbounded append of records nothing can read.
		# A band's history is meaningful within the world that grew it, so the chronicle is world-scoped.
		# (An injected service via set_service() is the caller's to manage: not repathed, not cleared.)
		_service.clear_backstory_space()
	_enable()
	var clock: LASimClock = LASimClock.active()
	if clock != null and not clock.day_advanced.is_connected(_on_day_advanced):
		clock.day_advanced.connect(_on_day_advanced)
	LASimReport.register(Callable(self, "report"))


## Use an already-built store instead of creating one. Must be called BEFORE the node enters the tree, the
## same ordering LocalAgentBackstoryGraphService.set_database_path documents: _ready() is what opens things.
func set_service(service: Node) -> void:
	_service = service
	_owns_service = false


func service() -> Node:
	return _service


## The store has to actually answer before anything else runs, so the first thing written is the world-time
## record for the current day — which doubles as the probe. A store that cannot be opened disables the
## chronicle with one warning rather than pushing an error per write for the rest of the run.
func _enable() -> void:
	if _service == null or not _service.has_method("set_world_time"):
		return
	var result: Variant = _service.call("set_world_time", LASimClock.world_day(), _season(), LASimClock.CALENDAR)
	if not (result is Dictionary) or not bool((result as Dictionary).get("ok", false)):
		push_warning("LABandChronicle: the backstory store is unavailable, so this world keeps no social history (%s)." % [result])
		return
	_enabled = true


func _season() -> String:
	var clock: LASimClock = LASimClock.active()
	return clock.season() if clock != null else ""


func _on_day_advanced(day: int) -> void:
	if not _enabled:
		return
	_service.call("set_world_time", day, _season(), LASimClock.CALENDAR)


func _process(delta: float) -> void:
	step(delta)


## One tick of the chronicle. Public and delta-driven so a test can advance it deterministically instead of
## waiting on frames.
func step(delta: float) -> void:
	if not _enabled:
		return
	_accum += delta
	if _accum < SCAN_PERIOD:
		return
	# Advance by what actually elapsed, not by one period: at a low frame rate (or under --fast) a single
	# delta can exceed SCAN_PERIOD, and counting periods instead of seconds would silently measure the dwell
	# in SCANS — making it frame-rate dependent, which is the mistake the inspector rules already log once.
	_now += _accum
	_accum = 0.0
	_scan()
	_drain(MAX_WRITES_PER_SCAN)


## Write out every queued membership change at once, and report how many were written. For a test, or for
## a caller that wants the store consistent before it reads (a save, a hand-off).
func flush() -> int:
	return _drain(_pending.size())


## O(population): one integer read per creature to tally band sizes, then one per creature to decide
## whether its band has settled into something worth recording.
func _scan() -> void:
	var tree: SceneTree = get_tree()
	if tree == null:
		return
	var live: Array = []
	var counts: Dictionary = {}
	for c in tree.get_nodes_in_group("creature"):
		if not is_instance_valid(c) or c.get("band_id") == null:
			continue
		live.append(c)
		var band: int = int(c.get("band_id"))
		counts[band] = int(counts.get(band, 0)) + 1
	var multi: int = 0
	for b in counts.keys():
		if int(counts[b]) > 1:
			multi += 1
	_band_count = multi

	var alive: Dictionary = {}
	for c in live:
		var cid: int = int(c.get_instance_id())
		alive[cid] = true
		var band: int = int(c.get("band_id"))
		# A band of one is not a faction — an animal on its own is simply unaffiliated (0).
		var target: int = band if int(counts.get(band, 0)) > 1 else 0
		# Dwell is measured on the TARGET, not on the raw band. A band of two whose other member wanders off
		# becomes a band of one without this creature's own integer changing at all, and that is exactly as
		# much a settling artefact as a relabel is — timing it from the band alone would let one animal's
		# churn write and rewrite its neighbour's record with no debounce at all.
		if int(_seen.get(cid, -1)) != target:
			_seen[cid] = target
			_since[cid] = _now
			_npc_ids[cid] = _npc_id_for(c)
		if int(_recorded.get(cid, 0)) == target:
			_pending.erase(cid)                       # it drifted back to what is already written
			continue
		if _now - float(_since.get(cid, _now)) < DWELL_SECONDS:
			continue                                  # still settling; not history yet
		_pending[cid] = target
	_reap(alive)


## A creature that left the tree (died, was removed) closes whatever membership it still held open. Death
## needs no hook of its own: it is simply the last day it was a member.
func _reap(alive: Dictionary) -> void:
	for cid_key in _seen.keys():
		var cid: int = int(cid_key)
		if alive.has(cid):
			continue
		if int(_recorded.get(cid, 0)) > 0:
			_pending[cid] = 0
		else:
			_forget(cid)


func _forget(cid: int) -> void:
	_seen.erase(cid)
	_since.erase(cid)
	_recorded.erase(cid)
	_npc_ids.erase(cid)
	_pending.erase(cid)
	_npc_ensured.erase(cid)


## Write up to `budget` queued changes. Each is at most: one npc upsert, one faction upsert, one close and
## one open — and the upserts happen once per creature and once per band for the whole run.
func _drain(budget: int) -> int:
	if budget <= 0 or _pending.is_empty():
		return 0
	var day: int = LASimClock.world_day()
	var done: int = 0
	for cid_key in _pending.keys():
		if done >= budget:
			break
		var cid: int = int(cid_key)
		var target: int = int(_pending[cid_key])
		var npc_id: String = String(_npc_ids.get(cid, ""))
		if npc_id == "":
			_pending.erase(cid_key)
			continue
		var previous: int = int(_recorded.get(cid, 0))
		if not _ensure_npc(cid, npc_id):
			_pending.erase(cid_key)
			continue
		if previous > 0:
			_service.call("close_relationship", npc_id, _faction_id(previous), "MEMBER_OF", day)
		if target > 0 and _ensure_faction(target):
			_service.call("add_relationship", npc_id, _faction_id(target), "MEMBER_OF", day, -1, 1.0, "association", true, {})
			_written += 1
		_recorded[cid] = target
		_pending.erase(cid_key)
		done += 1
		if not is_instance_id_valid(cid):
			_forget(cid)                              # the creature is gone and its record is closed
	return done


func _ensure_npc(cid: int, npc_id: String) -> bool:
	if bool(_npc_ensured.get(cid, false)):
		return true
	var result: Variant = _service.call("upsert_npc", npc_id, npc_id, {}, {})
	if not (result is Dictionary) or not bool((result as Dictionary).get("ok", false)):
		return false
	_npc_ensured[cid] = true
	return true


func _ensure_faction(band: int) -> bool:
	if bool(_faction_ensured.get(band, false)):
		return true
	var fid: String = _faction_id(band)
	var result: Variant = _service.call("upsert_faction", fid, "Band %d" % band, {"founded_day": LASimClock.world_day()})
	if not (result is Dictionary) or not bool((result as Dictionary).get("ok", false)):
		return false
	_faction_ensured[band] = true
	return true


## Stable within a run. Instance ids do not survive a reload, so a reloaded world starts a fresh chapter of
## the chronicle rather than continuing the previous animals' records — see the note in the return report.
func _npc_id_for(c) -> String:
	return "%s_%d" % [String(c.get("species")), int(c.get_instance_id())]


func _faction_id(band: int) -> String:
	return "band_%d" % band


## Telemetry into SIM_REPORT, so a launched run can show the clock advancing and the history being written
## without anyone reading the SQLite file.
func report() -> Dictionary:
	return {
		"sim_day": LASimClock.world_day(),
		"sim_days": snappedf(LASimClock.days_elapsed_now(), 0.01),
		"bands": _band_count,
		"memberships_written": _written,
	}
