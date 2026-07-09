class_name LAVoxelAudioController
extends Node

## Game-feel audio wiring for the voxel sim — presentation only, reacts to the sim, never drives it.
##
## This is thin WIRING over the existing procedural-audio subsystem (LocalAgentsAudioDirector +
## MusicDirector + SfxBank). It does NOT synthesize anything itself; it only:
##   1. salts the generative-music seed so each play session's bed evolves differently (the world
##      stays deterministic — the music seed is INDEPENDENT of the sim world seed);
##   2. subscribes to the emergent phenomenon-event tracker (LAEventTracker.event_emitted) and fires
##      one SFX STING per field phenomenon (eruption / wildfire / flood / storm / lightning / impact),
##      so field-derived events sound off even when no scripted disaster actor is present;
##   3. exposes reusable UI-sound + milestone-chime helpers the HUD/menus can call.
##
## Audibility is gated by the existing per-aspect bus mixer (audio starts muted; the player unmutes in
## the audio menu). This controller only WIRES the sources — it never force-unmutes. It degrades to
## silence + a warning if the audio director or event tracker is unavailable (e.g. headless: no audio
## device). No hard failure. (Explicit types only — project rule: no ':=' inferred typing.)

const AUDIO_GROUP: String = "local_agents_audio"

## Field-phenomenon type (from LAEventTracker) -> SFX preset key (from SynthPresets.sfx_presets()).
## Config over `if type == X`: a new phenomenon adds one row, not a branch. Unknown types fall back to
## FALLBACK_STING so a newly-added detector is still audible.
const PHENOMENON_STINGS: Dictionary = {
	"eruption": "volcano_rumble",   # deep molten-rock rumble as lava supply builds
	"wildfire": "fire",             # crackle of a spreading fire front
	"flood": "steam",               # rushing/hiss of fast-rising water
	"storm": "thunder",             # low roll of a gathering gale
	"lightning": "thunder",         # sharp thunder-clap per bolt
	"impact": "meteor_impact",      # heavy ground-shaking impact
}
const FALLBACK_STING: String = "impact_soft"
const MILESTONE_CHIME: String = "bell"    # positive objective/unlock cue (musical bell preset)
const UI_CLICK: String = "ui_click"

## Per-type sting cooldown (s) so a lingering phenomenon (fires burning for a while) doesn't machine-gun
## the sting. The tracker already samples at 1 Hz with detector rearm/cooldown; this is a cheap backstop.
const STING_COOLDOWN_S: float = 1.5

var _audio: Node = null                 # LocalAgentsAudioDirector (pulled off the world)
var _events: Node = null                # LAEventTracker (pulled off the world)
var _last_sting_time: Dictionary = {}   # type -> last wall-clock seconds a sting played
var _ready_ok: bool = false


## Wire from the composition root. Pulls the already-built audio director + event tracker off the world
## (no extra args), salts the music seed, and subscribes to the phenomenon-event signal. Safe if either
## dependency is missing — logs a warning and stays inert (silence), never crashes.
func setup(world: Node) -> void:
	if world == null:
		push_warning("VoxelAudioController: no world — audio wiring inert.")
		return
	_audio = world.get("_audio")
	_events = world.get("_events")
	if _audio == null:
		push_warning("VoxelAudioController: no AudioDirector — game-feel audio disabled (silent).")
		return
	_ready_ok = true

	_apply_audio_settings()
	_salt_music_seed()

	# Event stings: the ONE emergent phenomenon source drives the accents. Field-derived, so they fire
	# for events with no scripted actor (a purely-emergent eruption/wildfire/flood/storm).
	if _events != null and _events.has_signal("event_emitted"):
		var cb: Callable = Callable(self, "_on_phenomenon_event")
		if not _events.is_connected("event_emitted", cb):
			_events.event_emitted.connect(cb)
		print("AUDIO_CONTROLLER={ready:true, stings:%d, event_tracker:true}" % PHENOMENON_STINGS.size())
	else:
		print("AUDIO_CONTROLLER={ready:true, stings:%d, event_tracker:false}" % PHENOMENON_STINGS.size())


# --- Audio settings (bus volumes + on/off) --------------------------------------------------------

## Aspect bus -> the LAGameSettings volume field driving it. Master/Music/Sfx come straight from the
## player's sliders; Voice + Ui ride the master level (no separate slider). Config over a branch.
const BUS_VOLUME_FIELDS: Dictionary = {
	"Master": "master_volume",
	"Music": "music_volume",
	"Sfx": "sfx_volume",
	"Voice": "master_volume",
	"Ui": "master_volume",
}

## Apply the player's audio settings to the mixer and flip audio ON by default for the shipped game.
## Reconciles the old /root/GameSettings expectation with the real source (GameMode.settings — the typed
## LAGameSettings the front-end configures). A dev can silence everything with env LA_NO_AUDIO or the
## `--no-audio` launch arg (kept for headless/perf A-B runs); otherwise each bus takes its slider level.
func _apply_audio_settings() -> void:
	var settings: LAGameSettings = _game_settings()
	var audio_off: bool = _audio_disabled()
	if _audio != null:
		if _audio.has_method("set_enabled"):
			_audio.set_enabled(not audio_off)
		if _audio.has_method("set_music_enabled"):
			_audio.set_music_enabled(not audio_off)
		if _audio.has_method("set_sfx_enabled"):
			_audio.set_sfx_enabled(not audio_off)
	for bus_name in BUS_VOLUME_FIELDS:
		var bus_index: int = AudioServer.get_bus_index(bus_name)
		if bus_index < 0:
			continue
		var linear: float = 1.0
		if settings != null:
			linear = float(settings.get(String(BUS_VOLUME_FIELDS[bus_name])))
		var silent: bool = audio_off or linear <= 0.001
		AudioServer.set_bus_mute(bus_index, silent)
		if not silent:
			AudioServer.set_bus_volume_db(bus_index, linear_to_db(clampf(linear, 0.0, 1.0)))
	print("AUDIO_SETTINGS={off:%s, master:%.2f, music:%.2f, sfx:%.2f}" % [
		str(audio_off),
		(settings.master_volume if settings != null else 1.0),
		(settings.music_volume if settings != null else 1.0),
		(settings.sfx_volume if settings != null else 1.0)])


## The active LAGameSettings from the GameMode autoload (null in a direct-scene/test launch → defaults used).
func _game_settings() -> LAGameSettings:
	var gm: Node = get_node_or_null("/root/GameMode")
	if gm != null and gm.get("settings") != null:
		return gm.get("settings")
	return null


## True when audio should start silent. Default: SILENT in the editor + any debug run (i.e. all testing —
## no audio during the dev loop), audio ON only in the exported RELEASE build. Explicit override either way:
## `LA_NO_AUDIO=1` / `--no-audio` force silent; `LA_NO_AUDIO=0` / `--audio` force audio on (e.g. to test audio
## from the editor). The player's in-game volume/mute settings still apply on top of this default.
func _audio_disabled() -> bool:
	if OS.has_environment("LA_NO_AUDIO"):
		return OS.get_environment("LA_NO_AUDIO") != "0"
	for arg in OS.get_cmdline_user_args():
		if arg == "--no-audio":
			return true
		if arg == "--audio":
			return false
	return OS.has_feature("editor") or OS.is_debug_build()


# --- Music bed ------------------------------------------------------------------------------------

## Salt the generative-music seed for per-session variety. Precedence:
##   1. explicit override (env LA_MUSIC_SEED, or a GameSettings.music_seed if that autoload exists) —
##      for reproducible trailer/screenshot captures;
##   2. otherwise a fresh OS-entropy salt (randomize()), independent of the sim world seed.
## Feeds the salted value to the existing engine via reseed_music — never rebuilds the engine.
func _salt_music_seed() -> void:
	if _audio == null or not _audio.has_method("reseed_music"):
		return
	var seed: int = _resolve_music_seed()
	_audio.reseed_music(seed)
	print("MUSIC_SEED={value:%d, source:%s}" % [seed, _seed_source])


var _seed_source: String = "salt"

func _resolve_music_seed() -> int:
	# 1. env override
	if OS.has_environment("LA_MUSIC_SEED"):
		var raw: String = OS.get_environment("LA_MUSIC_SEED")
		if raw.is_valid_int():
			_seed_source = "env"
			return raw.to_int()
	# 2. optional GameSettings autoload override (absent in this build → skipped gracefully)
	var settings: Node = get_node_or_null("/root/GameSettings")
	if settings != null and settings.get("music_seed") != null:
		var pinned: int = int(settings.get("music_seed"))
		if pinned != 0:
			_seed_source = "settings"
			return pinned
	# 3. fresh per-session salt from OS entropy (independent of the deterministic world seed)
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.randomize()
	_seed_source = "salt"
	return int(rng.randi())


# --- Event stings ---------------------------------------------------------------------------------

## One SFX accent per emergent field phenomenon. Positional when the event carries a locus, else a flat
## cue. Volume scales gently with the event's intensity. Rate-limited per type. Cheap: O(1) dict lookup.
func _on_phenomenon_event(event) -> void:
	if not _ready_ok or _audio == null or event == null:
		return
	var kind: String = String(event.type)
	var now: float = float(Time.get_ticks_msec()) / 1000.0
	var last: float = float(_last_sting_time.get(kind, -1000.0))
	if now - last < STING_COOLDOWN_S:
		return
	_last_sting_time[kind] = now

	var key: String = String(PHENOMENON_STINGS.get(kind, FALLBACK_STING))
	# Intensity (~6 threshold .. ~24 disaster) -> a modest volume lift, clamped so it never clips.
	var vol_db: float = clampf((float(event.intensity) - 6.0) * 0.4, -4.0, 6.0)
	var locus: Variant = null
	if event.position is Vector3 and (event.position as Vector3) != Vector3.ZERO:
		locus = event.position
	# Fire the sting. `played` is false when SFX is muted/disabled at the bus (the default until the
	# player enables audio) — the REACTION still logs so the wiring is observable in a verification run.
	var played: bool = bool(_audio.play_sfx(key, locus, vol_db))
	print("AUDIO_STING={type:%s, sfx:%s, intensity:%.1f, played:%s}" % [kind, key, float(event.intensity), str(played)])


# --- Reusable helpers (HUD / menus call these) ----------------------------------------------------

## Positive milestone / objective / unlock chime. HUD calls this on an achievement; safe no-op if audio
## is unavailable. Non-positional (a UI cue).
func play_milestone() -> void:
	if _audio != null and _audio.has_method("play_sfx"):
		_audio.play_sfx(MILESTONE_CHIME)


## A UI click cue. Menus can call this instance method, or the static chime()/click() resolvers below
## (which find the live AudioDirector by group and need no controller reference).
func play_ui_click() -> void:
	if _audio != null and _audio.has_method("play_sfx"):
		_audio.play_sfx(UI_CLICK)


## Static UI-click helper — resolves the AudioDirector via its group, no controller reference needed.
## Menus another agent owns can call this directly: LAVoxelAudioController.ui_click(get_tree()).
static func ui_click(tree: SceneTree) -> void:
	_emit_via_group(tree, UI_CLICK)


## Static milestone-chime helper (same group resolution as ui_click).
static func chime(tree: SceneTree) -> void:
	_emit_via_group(tree, MILESTONE_CHIME)


static func _emit_via_group(tree: SceneTree, key: String) -> void:
	if tree == null:
		return
	var nodes: Array = tree.get_nodes_in_group(AUDIO_GROUP)
	if nodes.is_empty():
		return
	var director = nodes[0]
	if director != null and director.has_method("play_sfx"):
		director.play_sfx(key)
