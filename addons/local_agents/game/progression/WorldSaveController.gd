class_name LAWorldSaveController
extends Node


const StateScript: GDScript = preload("res://addons/local_agents/game/progression/WorldSaveState.gd")
const FieldSnapshotScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldSnapshot3D.gd")

## What the rewind history may hold, in bytes. DECISION, not a law. A moment is the whole field, so the
## depth of the ring is a memory budget and the number of moments is derived from what one costs.
const RING_BYTES: int = 1 << 30

static var _active: LAWorldSaveController = null

var _world = null
# Progression is a game-shell concept, so the presentation layer binds it; a headless sim has none.
var _progression: LAGameProgression = null
var _slot: String = LAGameSave.DEFAULT_SLOT      # the slot quick_save writes to (the loaded slot, or the default)
var _pending: Dictionary = {}                     # a loaded save awaiting the field-ready deferred restore
var _restore_pending: bool = false
var _restore_deadline: int = 0                    # frames to wait for the field before giving up (fail-graceful)
var _restore_min_wait: int = 0                    # frames to hold before applying (lets a live reset's queue_free complete)
# The cells of every held moment. GDScript holds handles into it, never the cells.
var _snapshots: LAFieldSnapshot = null
var _frame: int = 0
# --snapshot-roundtrip: capture, let the world diverge, restore in place, and report what came back.
var _rt_stage: int = 0                            # 0 off · 1 armed · 2 done
var _rt_handle: int = -1
var _rt_store: LAFieldSnapshot = null


static func active() -> LAWorldSaveController:
	return _active


func _ready() -> void:
	_active = self
	# ALWAYS so a deferred restore still completes while the tree is paused — the timeline pauses the sim during
	# a reverse scrub, and each rewind step's restore must finish across those paused frames.
	process_mode = Node.PROCESS_MODE_ALWAYS


func _exit_tree() -> void:
	if _active == self:
		_active = null


## Wire the controller to the world and kick off a load if the menu requested one. Called from LASimulation
## once every sim ref exists.
func setup(world) -> void:
	_world = world
	_parse_cli()
	var gm: Object = _game_mode()
	var slot: String = ""
	if gm != null and gm.has_method("take_pending_load_slot"):
		slot = gm.take_pending_load_slot()
	if slot == "":
		return                                    # a fresh New/Sandbox world — nothing to load
	_begin_load(slot)


func _parse_cli() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg == "--snapshot-roundtrip":
			_rt_stage = 1


## The game shell hands over its progression node; without one a save carries no stage. The shell builds
## after the sim, so a load already in flight replays its progression block here.
func bind_progression(progression: LAGameProgression) -> void:
	_progression = progression
	_apply_progression(_pending)


func _apply_progression(data: Dictionary) -> void:
	if _progression == null or data.is_empty() or not _progression.has_method("restore"):
		return
	_progression.restore(data.get("progression", {}))


func _game_mode() -> Object:
	var tree: SceneTree = get_tree()
	if tree == null or tree.root == null:
		return null
	return tree.root.get_node_or_null("GameMode")


# Load `slot`: read the blob, apply what needs no field/actors yet (progression), suppress the default spawn,
# and arm the deferred field+actors restore for once the field GPU is up.
func _begin_load(slot: String) -> void:
	var data: Dictionary = LAGameSave.read_world(slot)
	if data.is_empty():
		push_warning("LAWorldSaveController: save slot '%s' is missing or corrupt, so starting a fresh world" % slot)
		return
	_slot = slot
	_pending = data
	_restore_pending = true
	_restore_deadline = 3600                       # ~a minute of frames; ample for the field to stream + activate
	# Progression / mode apply immediately (independent of the field/actors streaming in).
	_apply_progression(data)
	# The saved world already holds its population — do NOT let the spawn controller seed a fresh one over it.
	if _world._spawn != null and _world._spawn.has_method("suppress_initial_spawn"):
		_world._spawn.suppress_initial_spawn()
	print("SAVE_LOAD_BEGIN={slot:%s, creatures:%d, fish:%d}" % [
		slot, (data.get("creatures", []) as Array).size(), (data.get("fish", []) as Array).size()])


func _process(_delta: float) -> void:
	_frame += 1
	if _rt_stage > 0:
		_run_snapshot_roundtrip()
	if not _restore_pending:
		return
	if _restore_min_wait > 0:
		_restore_min_wait -= 1                       # hold so a live reset's queue_free'd actors leave the tree first
		return
	_restore_deadline -= 1
	if _restore_deadline <= 0:
		push_warning("LAWorldSaveController: field never became ready, so actors are restored without the field")
		_finish_restore()
		return
	if FieldSnapshotScript.is_ready(_world._material):
		_finish_restore()


# The store the rewind history lives in, bounded by what RING_BYTES affords.
func _store() -> LAFieldSnapshot:
	if _snapshots == null:
		_snapshots = LAFieldSnapshot.new()
	if not FieldSnapshotScript.bind(_world._material, _snapshots):
		return null
	_snapshots.ring(snapshot_capacity())
	return _snapshots


## Moments of history the ring holds; 0 before the field is up.
func snapshot_capacity() -> int:
	if _snapshots == null:
		return 0
	var each: int = _snapshots.snapshot_bytes()
	return 0 if each <= 0 else maxi(1, RING_BYTES / each)


# A store of its own for work that must not evict a moment of history: writing a save, reading one back.
func _lone_store() -> LAFieldSnapshot:
	var store: LAFieldSnapshot = LAFieldSnapshot.new()
	return store if FieldSnapshotScript.bind(_world._material, store) else null


## The state of the whole world at this moment: its actors, and a handle to the field's cells.
func capture_snapshot() -> Dictionary:
	return _capture_into(_store())


func _capture_into(store: LAFieldSnapshot) -> Dictionary:
	if _world == null or _world._material == null or store == null:
		return {}
	var handle: int = store.capture()
	if handle < 0:
		return {}
	var state: Dictionary = StateScript.capture(_world, _progression)
	state["field"] = handle
	return state


# The pending block is a live handle the ring owns, or the bytes a save file holds. Disk is the only place
# the cells are ever bytes, so that is the one place a handle is minted here and released again.
func _finish_restore() -> void:
	_restore_pending = false
	var block: Variant = _pending.get("field", -1)
	var from_disk: bool = block is PackedByteArray
	var store: LAFieldSnapshot = _lone_store() if from_disk else _store()
	if store != null:
		var handle: int = store.deserialize(block) if from_disk else int(block)
		if handle >= 0:
			FieldSnapshotScript.restore(_world._material, store, handle)
	var n: int = StateScript.apply_actors(_world, _pending)
	print("SAVE_LOAD_DONE={slot:%s, creatures_restored:%d}" % [_slot, n])
	_pending = {}


## Snapshot the whole world to the current slot. Called by the pause-menu "Save game" entry. Returns OK, or an
## error / FAILED when the world is not in a saveable state. Timestamp is captured here (a header field only —
## it never feeds the simulation, so it can't break determinism).
func quick_save() -> int:
	return save_to_slot(_slot)


func save_to_slot(slot: String) -> int:
	if _world == null:
		return FAILED
	var store: LAFieldSnapshot = _lone_store()
	var state: Dictionary = _capture_into(store)
	if state.is_empty():
		return FAILED
	# The one place the cells become bytes: a file cannot hold a handle.
	state["field"] = store.serialize(int(state.get("field", -1)))
	var population: int = (state.get("creatures", []) as Array).size()
	var stage: int = 0
	if _progression != null and _progression.has_method("current_stage"):
		stage = _progression.current_stage()
	var gm: Object = _game_mode()
	var header: Dictionary = {
		"timestamp": int(Time.get_unix_time_from_system()),
		"mode": (gm.mode_name() if gm != null and gm.has_method("mode_name") else "campaign"),
		"seed": 1337,
		"name": slot,
		"population": population,
		"progression_stage": stage,
	}
	var settings: Resource = gm.settings if gm != null and "settings" in gm else null
	var err: int = LAGameSave.write_world(slot, header, state, settings)
	print("SAVE_WRITE={slot:%s, err:%d, population:%d, stage:%d}" % [slot, err, population, stage])
	return err


## Full field steps since the seal, or -1 with no field: what a snapshot is keyed on.
func field_version() -> int:
	if _world == null or _world._material == null:
		return -1
	return _world._material.step_driver().full_steps()


## Release a held moment's cells (the timeline evicting or forking away from one).
func drop_snapshot(data: Dictionary) -> void:
	if _snapshots == null:
		return
	var handle: int = int(data.get("field", -1))
	if handle >= 0:
		_snapshots.drop(handle)


## True while a restore is mid-flight (the caller should not capture or restore again until it clears).
func is_restoring() -> bool:
	return _restore_pending


## Restore a snapshot IN PLACE (live rewind/fork): wipe the current population + registries, then re-apply the
## snapshot's field + actors once the freed nodes have left the tree and the field is ready. Deferred via the
## same _restore_pending path as a disk load, plus a short min-wait for the reset's queue_free to complete.
func restore_snapshot(data: Dictionary) -> void:
	if _world == null or data.is_empty() or _restore_pending:
		return
	if _world._ecology != null and _world._ecology.has_method("reset_world"):
		_world._ecology.reset_world()
	_pending = data.duplicate(true)                 # own a copy — the ring keeps the original
	_restore_pending = true
	_restore_min_wait = 2
	_restore_deadline = 3600
	if _progression != null and _progression.has_method("restore"):
		_progression.restore(data.get("progression", {}))


# THE SNAPSHOT'S OWN PROOF, run inside the seeded world on its own device. The world it stands in may be
# at rest, so the state a restore has to overwrite is made rather than waited for: wipe the cells to
# nothing, put the capture back, and read every channel again — from memory and through the save bytes.
func _run_snapshot_roundtrip() -> void:
	if _rt_stage != 1 or _frame < 60 or not FieldSnapshotScript.is_ready(_world._material):
		return
	_rt_store = _lone_store()
	if _rt_store == null:
		return
	_rt_stage = 2
	var store: LAFieldSnapshot = _rt_store
	var field = _world._material
	_rt_handle = store.capture()
	var wiped: int = store.blank()

	# THE CONTROL. The wipe must reach the device, or a restore that did nothing would read as exact.
	FieldSnapshotScript.restore(field, store, wiped)
	var h: int = store.capture()
	var took: int = int((store.compare(wiped, h) as Dictionary).get("cells", -1))
	var lost: int = int((store.compare(_rt_handle, h) as Dictionary).get("cells", -1))
	store.drop(h)

	FieldSnapshotScript.restore(field, store, _rt_handle)
	var mirrors: int = store.apply_mirrors(_rt_handle, field)
	h = store.capture()
	var same: int = int((store.compare(_rt_handle, h) as Dictionary).get("cells", -1))
	var totals_differ: int = _totals_differ(store.totals(_rt_handle), store.totals(h))
	var nonzero: int = _nonzero_totals(store.totals(_rt_handle))
	store.drop(h)

	var blob: PackedByteArray = store.serialize(_rt_handle)
	var bytes: int = blob.size()
	h = store.deserialize(blob)
	blob = PackedByteArray()
	FieldSnapshotScript.restore(field, store, wiped)
	FieldSnapshotScript.restore(field, store, h)
	store.drop(h)
	h = store.capture()
	var save_same: int = int((store.compare(_rt_handle, h) as Dictionary).get("cells", -1))
	store.drop(h)

	# A snapshot of a world this is not must refuse rather than overwrite: point the store elsewhere and ask.
	store.bind(field._gpu._rd, {}, PackedStringArray(), field._cell_count, null)
	var refused: bool = not store.restore(_rt_handle)

	var declared: int = LAChannels.channels().size() + LAMaterialSphereGPU3D.SEED_PRODUCTS.size()
	print("SNAPSHOT_ROUNDTRIP={layout:%d, channels:%d, declared:%d, cells:%d, mirrors:%d, took:%d, lost:%d, same:%d, save_same:%d, nonzero:%d, totals_differ:%d, refused:%d, bytes:%d}" % [
		LAFieldSnapshot.LAYOUT_VERSION, store.channels(_rt_handle).size(), declared,
		store.cell_count(_rt_handle), mirrors, took, lost, same, save_same, nonzero, totals_differ,
		1 if refused else 0, bytes])
	store.drop(_rt_handle)
	store.drop(wiped)


func _nonzero_totals(t: Dictionary) -> int:
	var n: int = 0
	for k in t:
		if float(t[k]) != 0.0:
			n += 1
	return n


func _totals_differ(a: Dictionary, b: Dictionary) -> int:
	var n: int = 0
	for k in a:
		if not b.has(k) or float(a[k]) != float(b[k]):
			n += 1
	return n
