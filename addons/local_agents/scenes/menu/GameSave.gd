class_name LAGameSave
extends RefCounted

## LAGameSave — the slot catalogue + on-disk plumbing for world saves. The main menu queries it to decide
## whether "Continue" is enabled and which slot to resume; the sim's save controller (LAWorldSaveController)
## calls it to WRITE and READ the heavy world blob. This file owns only the disk layout + catalogue reads —
## the actual gather/apply of world state lives in LAWorldSaveState (creatures/kinship/progression) and
## LAMaterialFieldSnapshot3D (the field), keeping this a thin plumbing/catalogue facade.
##
## Layout — one directory per slot under a saves root:
##   user://local_agents/saves/<slot>/meta.cfg    ConfigFile header (version, timestamp, mode, seed, name,
##                                                 population, progression_stage) — cheap to read for the menu
##   user://local_agents/saves/<slot>/world.sav   binary FileAccess.store_var of the one big state Dictionary
##                                                 (field channels + actors + kinship + progression)
##   user://local_agents/saves/<slot>/settings.res the active LAGameSettings resource (ResourceSaver)
##
## Everything fails GRACEFULLY: a missing/corrupt slot reads back as an empty dict (never a crash), so the
## menu simply keeps Continue disabled and the sim boots a fresh world. (Explicit types only — no ':=' typing.)

const SAVES_ROOT: String = "user://local_agents/saves"
const SAVE_VERSION: int = 1
const META_FILE: String = "meta.cfg"
const WORLD_FILE: String = "world.sav"
const SETTINGS_FILE: String = "settings.res"
const META_SECTION: String = "meta"
const DEFAULT_SLOT: String = "slot0"


## Absolute user:// path of a slot's directory (not created here — write_world() makes it).
static func slot_dir(slot: String) -> String:
	return "%s/%s" % [SAVES_ROOT, slot]


## True when a resumable save exists in ANY slot — the menu's Continue gate. A slot counts only when its
## world blob is present (a bare/half-written directory does not enable Continue).
static func has_save() -> bool:
	return not list_slots().is_empty()


## Every slot with a readable world blob, each as its meta header {slot, version, timestamp, mode, name,
## population, progression_stage, seed}, newest first. Cheap: one ConfigFile read per slot, no world load.
static func list_slots() -> Array:
	var out: Array = []
	var dir: DirAccess = DirAccess.open(SAVES_ROOT)
	if dir == null:
		return out
	for name in dir.get_directories():
		if not FileAccess.file_exists("%s/%s" % [slot_dir(name), WORLD_FILE]):
			continue
		var meta: Dictionary = read_meta(name)
		meta["slot"] = name
		out.append(meta)
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a.get("timestamp", 0)) > int(b.get("timestamp", 0)))
	return out


## The most-recently-written slot's id, or "" when none exists — what Continue resumes.
static func latest_slot() -> String:
	var slots: Array = list_slots()
	return String((slots[0] as Dictionary).get("slot", "")) if not slots.is_empty() else ""


## Read a slot's cheap header (ConfigFile). Empty dict if absent/unreadable. Never loads the world blob.
static func read_meta(slot: String) -> Dictionary:
	var cfg: ConfigFile = ConfigFile.new()
	if cfg.load("%s/%s" % [slot_dir(slot), META_FILE]) != OK:
		return {}
	return {
		"version": int(cfg.get_value(META_SECTION, "version", 0)),
		"timestamp": int(cfg.get_value(META_SECTION, "timestamp", 0)),
		"mode": String(cfg.get_value(META_SECTION, "mode", "campaign")),
		"name": String(cfg.get_value(META_SECTION, "name", slot)),
		"population": int(cfg.get_value(META_SECTION, "population", 0)),
		"progression_stage": int(cfg.get_value(META_SECTION, "progression_stage", 0)),
		"seed": int(cfg.get_value(META_SECTION, "seed", 0)),
	}


## WRITE a save: the meta header (ConfigFile), the heavy world blob (binary store_var) and the settings
## resource. Creates the slot directory. Returns OK, or an error code on the first failure (partial writes are
## left for the caller to surface — a later read of a half-written slot fails gracefully to empty).
static func write_world(slot: String, header: Dictionary, world_state: Dictionary, settings: Resource) -> int:
	var dir_path: String = slot_dir(slot)
	var mk: int = DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir_path))
	if mk != OK and not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(dir_path)):
		# Fall back to the user:// virtual path maker (globalize can differ under --path); tolerate either.
		DirAccess.make_dir_recursive_absolute(dir_path)

	var cfg: ConfigFile = ConfigFile.new()
	cfg.set_value(META_SECTION, "version", SAVE_VERSION)
	for k in header.keys():
		cfg.set_value(META_SECTION, String(k), header[k])
	var meta_err: int = cfg.save("%s/%s" % [dir_path, META_FILE])
	if meta_err != OK:
		return meta_err

	var f: FileAccess = FileAccess.open("%s/%s" % [dir_path, WORLD_FILE], FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_var(world_state, true)      # full_objects=true so PackedFloat32Array/Dictionary/Vector3 round-trip
	f.close()

	if settings != null:
		ResourceSaver.save(settings, "%s/%s" % [dir_path, SETTINGS_FILE])
	return OK


## READ a slot's heavy world blob back into a Dictionary. Empty dict on any failure (missing / unreadable /
## corrupt / wrong type) — the caller then boots a fresh world instead of crashing.
static func read_world(slot: String) -> Dictionary:
	var path: String = "%s/%s" % [slot_dir(slot), WORLD_FILE]
	if not FileAccess.file_exists(path):
		return {}
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var v: Variant = f.get_var(true)
	f.close()
	return v if v is Dictionary else {}


## READ a world blob from an ARBITRARY directory (a committed test fixture, not a user:// slot). Same
## graceful get_var(true) plumbing as read_world, sourced from `<dir>/world.sav` — the deterministic
## fixture-load path (LAWorldSaveController --load-fixture) uses this so a committed save round-trips
## without shuffling files into the user:// saves root. Empty dict on any failure.
static func read_world_dir(dir: String) -> Dictionary:
	var path: String = "%s/%s" % [dir, WORLD_FILE]
	if not FileAccess.file_exists(path):
		return {}
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var v: Variant = f.get_var(true)
	f.close()
	return v if v is Dictionary else {}


## READ a slot's persisted settings resource, or null if absent/unreadable.
static func read_settings(slot: String) -> Resource:
	var path: String = "%s/%s" % [slot_dir(slot), SETTINGS_FILE]
	if not FileAccess.file_exists(path):
		return null
	return ResourceLoader.load(path)
