class_name LAGameSave
extends RefCounted

## LAGameSave — the save-slot facade the main menu queries to decide whether "Continue" is enabled.
## The persistence system is not built yet, so `has_save()` is a real check against a save path that
## simply returns false until a save is ever written — the menu wires to this call now, and the day
## saving lands, only this file changes (the menu needs no edit). (Explicit types only — no ':=' typing.)

const SAVE_PATH: String = "user://savegame.dat"


## True when a resumable save exists. Stubbed to a real file-existence check (no save is ever written
## yet, so it is false today), so "Continue" stays correctly disabled until saving is implemented.
static func has_save() -> bool:
	return FileAccess.file_exists(SAVE_PATH)
