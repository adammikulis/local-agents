class_name LAWorldSaveController
extends Node

## LAWorldSaveController — the live save/load orchestrator wired into VoxelWorld (one add_child + setup line;
## the composition root stays extract-only). It:
##   * on boot, reads GameMode.take_pending_load_slot(); if a slot was requested (menu → Continue), it loads
##     that slot: progression/mode are applied at once, the default initial spawn is SUPPRESSED, and the heavy
##     FIELD + ACTORS restore is deferred until the field's GPU driver has activated (a few frames in).
##   * exposes quick_save() (the pause-menu "Save game" entry) which snapshots the whole world to the current
##     slot through LAWorldSaveState + LAGameSave.
##
## The gather/apply logic lives in LAWorldSaveState (actors/kinship/progression) and LAMaterialFieldSnapshot3D
## (field); this node only sequences them against boot timing + the current slot. A static active() lets the
## deep pause menu reach the one controller without threading a reference through the input stack.
## (Explicit types only — no ':=' inferred typing.)

const StateScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/game/WorldSaveState.gd")
const FieldSnapshotScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/MaterialFieldSnapshot3D.gd")

static var _active: LAWorldSaveController = null

var _world = null
var _slot: String = LAGameSave.DEFAULT_SLOT      # the slot quick_save writes to (the loaded slot, or the default)
var _pending: Dictionary = {}                     # a loaded save awaiting the field-ready deferred restore
var _restore_pending: bool = false
var _restore_deadline: int = 0                    # frames to wait for the field before giving up (fail-graceful)
var _restore_min_wait: int = 0                    # frames to hold before applying (lets a live reset's queue_free complete)
# --timeline-selftest: capture at frame 300, let the world diverge, restore in place at 600, print state each
# step. Proves the in-memory capture + live reset + restore round-trips (population/kinship/field return).
var _selftest_stage: int = 0                      # 0 off · 1 armed · 2 captured · 3 restoring · 4 done
var _selftest_snap: Dictionary = {}
# Headless round-trip harness hooks (CLI): --save-slot=NAME [--save-frame=N] auto-saves at frame N and prints a
# deterministic state line; --load-slot=NAME resumes that slot (equivalent to the menu Continue).
var _auto_save_slot: String = ""
var _auto_save_frame: int = 0
var _frame: int = 0
var _auto_saved: bool = false
# Deterministic fixture-load path (CLI): --load-fixture=<dir> restores a COMMITTED save directory (a repo
# test fixture) instead of a user:// slot — no file shuffling, so the round-trip check is reproducible.
var _load_fixture_dir: String = ""


static func active() -> LAWorldSaveController:
	return _active


func _ready() -> void:
	_active = self


func _exit_tree() -> void:
	if _active == self:
		_active = null


## Wire the controller to the world and kick off a load if the menu requested one. Called from VoxelWorld at
## the end of _ready (every scene ref exists by then).
func setup(world) -> void:
	_world = world
	_parse_cli()
	# A committed fixture (--load-fixture=<dir>) takes precedence: it's the deterministic verification path.
	if _load_fixture_dir != "":
		_begin_load_dir(_load_fixture_dir)
		return
	var gm: Object = _game_mode()
	var slot: String = ""
	if gm != null and gm.has_method("take_pending_load_slot"):
		slot = gm.take_pending_load_slot()
	if slot == "":
		return                                    # a fresh New/Sandbox world — nothing to load
	_begin_load(slot)


# Round-trip harness CLI: --load-slot=NAME (resume, like Continue), --save-slot=NAME [--save-frame=N] (auto
# snapshot at frame N, default 400). Parsed once at setup; a --load-slot pre-arms the GameMode pending slot.
func _parse_cli() -> void:
	for arg in OS.get_cmdline_user_args():
		# --load-slot is handled by the GameMode autoload (it must arm campaign mode BEFORE progression readies);
		# here we only parse the auto-save hooks.
		if arg.begins_with("--save-slot="):
			_auto_save_slot = arg.substr("--save-slot=".length())
		elif arg.begins_with("--save-frame="):
			_auto_save_frame = int(arg.substr("--save-frame=".length()))
		elif arg.begins_with("--load-fixture="):
			_load_fixture_dir = arg.substr("--load-fixture=".length())
		elif arg == "--timeline-selftest":
			_selftest_stage = 1
	if _auto_save_slot != "" and _auto_save_frame <= 0:
		_auto_save_frame = 400


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
		push_warning("LAWorldSaveController: save slot '%s' missing or corrupt — starting a fresh world" % slot)
		return
	_slot = slot
	_pending = data
	_restore_pending = true
	_restore_deadline = 3600                       # ~a minute of frames; ample for the field to stream + activate
	# Progression / mode apply immediately (independent of the field/actors streaming in).
	if _world._progression != null and _world._progression.has_method("restore"):
		_world._progression.restore(data.get("progression", {}))
	# The saved world already holds its population — do NOT let the spawn controller seed a fresh one over it.
	if _world._spawn != null and _world._spawn.has_method("suppress_initial_spawn"):
		_world._spawn.suppress_initial_spawn()
	print("SAVE_LOAD_BEGIN={slot:%s, creatures:%d, fish:%d}" % [
		slot, (data.get("creatures", []) as Array).size(), (data.get("fish", []) as Array).size()])


# Load a COMMITTED fixture directory (--load-fixture=<dir>): identical restore path to _begin_load, but the
# blob is read from an explicit repo dir via LAGameSave.read_world_dir (no user:// slot). The saved grid must
# match the live one — the fixture is authored + loaded under --smoke so the Potato cell_count lines up.
func _begin_load_dir(dir: String) -> void:
	var data: Dictionary = LAGameSave.read_world_dir(dir)
	if data.is_empty():
		push_warning("LAWorldSaveController: fixture '%s' missing or corrupt — starting a fresh world" % dir)
		return
	_slot = LAGameSave.DEFAULT_SLOT
	_pending = data
	_restore_pending = true
	_restore_deadline = 3600
	if _world._progression != null and _world._progression.has_method("restore"):
		_world._progression.restore(data.get("progression", {}))
	if _world._spawn != null and _world._spawn.has_method("suppress_initial_spawn"):
		_world._spawn.suppress_initial_spawn()
	print("SAVE_LOAD_BEGIN={fixture:%s, creatures:%d, fish:%d}" % [
		dir, (data.get("creatures", []) as Array).size(), (data.get("fish", []) as Array).size()])


func _process(_delta: float) -> void:
	_frame += 1
	if _selftest_stage > 0:
		_run_timeline_selftest()
	# Headless auto-save hook: snapshot once the field is up AND the target frame has arrived.
	if _auto_save_slot != "" and not _auto_saved and _frame >= _auto_save_frame \
			and FieldSnapshotScript.is_ready(_world._material):
		_auto_saved = true
		save_to_slot(_auto_save_slot)
		_emit_state("SAVE_STATE_SAVED")
	if not _restore_pending:
		return
	if _restore_min_wait > 0:
		_restore_min_wait -= 1                       # hold so a live reset's queue_free'd actors leave the tree first
		return
	_restore_deadline -= 1
	if _restore_deadline <= 0:
		push_warning("LAWorldSaveController: field never became ready — actors restored without the field")
		_finish_restore()
		return
	if FieldSnapshotScript.is_ready(_world._material):
		_finish_restore()


## Headless proof of the in-place snapshot round-trip. Emits TL_* state lines: the captured snapshot, the
## diverged world just before restore, and the restored world (which should match the capture).
func _run_timeline_selftest() -> void:
	if _selftest_stage == 1 and _frame >= 300 and FieldSnapshotScript.is_ready(_world._material):
		_selftest_snap = capture_snapshot()
		_selftest_stage = 2 if not _selftest_snap.is_empty() else 1
		if _selftest_stage == 2:
			_emit_state("TL_CAPTURED")
	elif _selftest_stage == 2 and _frame >= 600:
		_emit_state("TL_BEFORE_RESTORE")
		restore_snapshot(_selftest_snap)
		_selftest_stage = 3
	elif _selftest_stage == 3 and not _restore_pending:
		_emit_state("TL_RESTORED")           # should match TL_CAPTURED (population/habits/families/mineral)
		_selftest_stage = 4


func _finish_restore() -> void:
	_restore_pending = false
	FieldSnapshotScript.restore(_world._material, _pending.get("field", {}))
	var n: int = StateScript.apply_actors(_world, _pending)
	print("SAVE_LOAD_DONE={slot:%s, creatures_restored:%d}" % [_slot, n])
	_pending = {}
	_emit_state("SAVE_STATE_LOADED")


# Print a deterministic aggregate line for round-trip verification: populations, total learned habits (Σ policy
# sizes across creatures — proves cognition survived), kinship component count, progression stage, and the field
# conservation totals (h2o/mineral/biomass). Compared between the pre-save world and the reloaded world.
func _emit_state(tag: String) -> void:
	var tree: SceneTree = get_tree()
	var creatures: int = 0
	var habits: int = 0
	var sample_habits: int = -1
	for c in tree.get_nodes_in_group("creature"):
		if not is_instance_valid(c):
			continue
		creatures += 1
		var cog = c.get_cognition() if c.has_method("get_cognition") else null
		if cog != null:
			var sz: int = cog.policy.size()
			habits += sz
			if sample_habits < 0:
				sample_habits = sz
	var fish: int = tree.get_nodes_in_group("fish").size()
	var families: int = 0
	if _world._ecology != null and _world._ecology.has_method("kinship"):
		families = _world._ecology.kinship().family_count()
	var stage: int = _world._progression.current_stage() if _world._progression != null else -1
	var field = _world._material
	var h2o: float = field.h2o_total() if field != null and field.has_method("h2o_total") else 0.0
	var mineral: float = 0.0
	var biomass: float = field.biomass_total() if field != null and field.has_method("biomass_total") else 0.0
	if field != null and field.has_method("report"):
		mineral = float((field.report() as Dictionary).get("mineral_total", 0.0))
	print("%s={creatures:%d, fish:%d, habits:%d, sample_habits:%d, families:%d, stage:%d, h2o:%.2f, mineral:%.2f, biomass:%.2f}" % [
		tag, creatures, fish, habits, sample_habits, families, stage, h2o, mineral, biomass])


## Snapshot the whole world to the current slot. Called by the pause-menu "Save game" entry. Returns OK, or an
## error / FAILED when the world is not in a saveable state. Timestamp is captured here (a header field only —
## it never feeds the simulation, so it can't break determinism).
func quick_save() -> int:
	return save_to_slot(_slot)


func save_to_slot(slot: String) -> int:
	if _world == null:
		return FAILED
	var state: Dictionary = StateScript.capture(_world)
	var population: int = (state.get("creatures", []) as Array).size()
	var stage: int = 0
	if _world._progression != null and _world._progression.has_method("current_stage"):
		stage = _world._progression.current_stage()
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


# --- Timeline snapshots (in-memory rewind/fork; no disk) -----------------------------------------------------
# A snapshot is exactly the whole-world state dict StateScript.capture() builds — the same blob quick_save
# writes, just held in RAM by the timeline ring instead of a file. Restore wipes the live world and re-applies
# it in place, reusing the deferred field-ready restore machinery.

## Capture the whole world to an in-memory dict (no file). Requires the field to be ready (else returns {}).
func capture_snapshot() -> Dictionary:
	if _world == null or _world._material == null:
		return {}
	if not FieldSnapshotScript.is_ready(_world._material):
		return {}
	return StateScript.capture(_world)


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
	if _world._progression != null and _world._progression.has_method("restore"):
		_world._progression.restore(data.get("progression", {}))
