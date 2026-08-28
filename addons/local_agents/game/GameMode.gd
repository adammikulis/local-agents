extends Node


enum Mode { CAMPAIGN, SANDBOX }

## Emitted by apply(): the sim connects to receive the settings to push into its systems.
signal settings_applied(settings: LAGameSettings)

## Emitted by start_*(): the sim can read `mode` on the next scene, or react to a live change.
signal mode_changed(mode: int)

var mode: int = Mode.SANDBOX
var settings: LAGameSettings = null

var pending_load_slot: String = ""


## Ask the next sim launch to resume from `slot` (in campaign mode — a save is always a campaign world).
func request_load(slot: String) -> void:
	pending_load_slot = slot
	mode = Mode.CAMPAIGN
	mode_changed.emit(mode)


## The pending load slot, consumed once by the save controller so a later New/Sandbox launch starts fresh.
func take_pending_load_slot() -> String:
	var slot: String = pending_load_slot
	pending_load_slot = ""
	return slot


func _ready() -> void:
	# Load the persisted settings once so any scene (menu or sim) can read GameMode.settings.
	if settings == null:
		settings = LAGameSettings.load_or_default()
	for arg in OS.get_cmdline_user_args():
		if arg == "--campaign":
			mode = Mode.CAMPAIGN
		elif arg == "--sandbox":
			mode = Mode.SANDBOX
		elif arg.begins_with("--load-slot="):
			mode = Mode.CAMPAIGN
			pending_load_slot = arg.substr("--load-slot=".length())


## Select campaign mode (progression gating on) for the next sim launch.
func start_campaign() -> void:
	mode = Mode.CAMPAIGN
	pending_load_slot = ""          # a fresh campaign, not a resume
	mode_changed.emit(mode)


## Select sandbox mode (progression gating off) for the next sim launch.
func start_sandbox() -> void:
	mode = Mode.SANDBOX
	pending_load_slot = ""          # a fresh sandbox, not a resume
	mode_changed.emit(mode)


func is_campaign() -> bool:
	return mode == Mode.CAMPAIGN


func is_sandbox() -> bool:
	return mode == Mode.SANDBOX


func mode_name() -> String:
	return "campaign" if mode == Mode.CAMPAIGN else "sandbox"


func apply(new_settings: LAGameSettings) -> void:
	if new_settings != null:
		settings = new_settings
	settings_applied.emit(settings)
