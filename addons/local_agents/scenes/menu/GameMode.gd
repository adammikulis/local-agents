extends Node

## LAGameMode — the autoload that carries the launch choice ACROSS the change_scene_to_file boundary
## from the main menu into the sim (a scene switch tears down the old tree, so a static/autoload is the
## only thing that survives). It holds two things the sim reads on boot:
##   - `mode`     — CAMPAIGN (progression gating ON) vs SANDBOX (gating OFF). The progression system,
##                  once it exists, reads `is_campaign()` to decide whether to gate content.
##   - `settings` — the active LAGameSettings the player configured (or the persisted defaults).
##
## APPLICATION INTERFACE (the sim consumes this later — not wired here): call `apply(settings)` to set
## the active settings and broadcast `settings_applied(settings)`. A future VoxelWorld pass connects to
## that signal (or just reads `GameMode.settings` in _ready) and pushes the values into the field/spawn/
## disaster systems. This autoload only STORES and BROADCASTS; it never touches simulation code.
##
## Registered as the `GameMode` autoload in project.godot. (Explicit types only — no ':=' inferred typing.)

enum Mode { CAMPAIGN, SANDBOX }

## Emitted by apply(): the sim connects to receive the settings to push into its systems.
signal settings_applied(settings: LAGameSettings)

## Emitted by start_*(): the sim can read `mode` on the next scene, or react to a live change.
signal mode_changed(mode: int)

var mode: int = Mode.SANDBOX
var settings: LAGameSettings = null


func _ready() -> void:
	# Load the persisted settings once so any scene (menu or sim) can read GameMode.settings.
	if settings == null:
		settings = LAGameSettings.load_or_default()


## Select campaign mode (progression gating on) for the next sim launch.
func start_campaign() -> void:
	mode = Mode.CAMPAIGN
	mode_changed.emit(mode)


## Select sandbox mode (progression gating off) for the next sim launch.
func start_sandbox() -> void:
	mode = Mode.SANDBOX
	mode_changed.emit(mode)


func is_campaign() -> bool:
	return mode == Mode.CAMPAIGN


func is_sandbox() -> bool:
	return mode == Mode.SANDBOX


func mode_name() -> String:
	return "campaign" if mode == Mode.CAMPAIGN else "sandbox"


## Store the active settings and broadcast them for the sim to apply. The single application entry point.
func apply(new_settings: LAGameSettings) -> void:
	if new_settings != null:
		settings = new_settings
	settings_applied.emit(settings)
