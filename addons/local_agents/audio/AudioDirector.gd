@tool
extends Node
class_name LocalAgentsAudioDirector

## Presentation-layer composition root for all procedural audio.
##
## Owns the swappable synth voice, the SFX bank + voice pool, and the generative
## MusicDirector. Sim/actor code reaches it via the "local_agents_audio" group and
## calls `play_sfx(...)`; WorldSimulation feeds `set_music_mood(...)` each frame.
## It never reads or writes simulation-authoritative state — it only reacts.

const GdScriptSynthVoice := preload("res://addons/local_agents/audio/synth/GdScriptSynthVoice.gd")
const SfxBank := preload("res://addons/local_agents/audio/SfxBank.gd")
const AudioVoicePool := preload("res://addons/local_agents/audio/AudioVoicePool.gd")
const MusicDirector := preload("res://addons/local_agents/audio/MusicDirector.gd")

const AUDIO_GROUP := "local_agents_audio"
const DEFAULT_SAMPLE_RATE := 44100

@export var enabled: bool = true
@export var music_enabled: bool = true
@export var sfx_enabled: bool = true

var _voice: LocalAgentsSynthVoice = null
var _sfx: LocalAgentsSfxBank = null
var _pool: LocalAgentsAudioVoicePool = null
var _music: LocalAgentsMusicDirector = null
var _jitter := RandomNumberGenerator.new()

func _ready() -> void:
	add_to_group(AUDIO_GROUP)

## Static convenience: fire an SFX from anywhere given a SceneTree, without holding
## a reference. Resolves the active AudioDirector via its group. No-op if none.
## Pass a Vector3 for a positional sound; omit for a non-positional one.
static func emit(tree: SceneTree, key: String, world_position: Variant = null) -> bool:
	if tree == null:
		return false
	var nodes: Array = tree.get_nodes_in_group(AUDIO_GROUP)
	if nodes.is_empty():
		return false
	var director = nodes[0]
	if director != null and director.has_method("play_sfx"):
		return bool(director.play_sfx(key, world_position))
	return false

## Build the audio stack. Call once after adding to the tree.
func configure(
	voice: LocalAgentsSynthVoice = null,
	sample_rate: int = DEFAULT_SAMPLE_RATE,
	music_seed: int = 1337
) -> void:
	_voice = voice if voice != null else GdScriptSynthVoice.new()
	_jitter.seed = 20260704

	_sfx = SfxBank.new()
	_sfx.configure(_voice, sample_rate)

	_pool = AudioVoicePool.new()
	_pool.name = "AudioVoicePool"
	add_child(_pool)
	_pool.configure()

	_music = MusicDirector.new()
	_music.name = "MusicDirector"
	add_child(_music)
	_music.configure(_voice, sample_rate, music_seed)

	_apply_enabled_state()

# --- SFX ------------------------------------------------------------------------

## Play a named SFX. Pass a `Vector3` world position for a spatialized (3D) sound;
## omit it (or pass null) for a non-positional UI/ambient sound. Returns false if
## disabled, unknown key, or suppressed by cooldown.
func play_sfx(key: String, world_position: Variant = null, volume_db: float = 0.0, pitch_variance: float = 0.06) -> bool:
	if not enabled or not sfx_enabled or _sfx == null or _pool == null:
		return false
	var stream := _sfx.get_stream(key)
	if stream == null:
		return false
	var pitch := 1.0 + _jitter.randf_range(-pitch_variance, pitch_variance)
	var vol := volume_db + _jitter.randf_range(-1.5, 1.5)
	if world_position is Vector3:
		return _pool.play_positional(stream, world_position, pitch, vol, key)
	return _pool.play_nonpositional(stream, pitch, vol, &"Ui", key)

## Register/override a custom SFX preset (see SynthPresets for the field shape).
func register_sfx(key: String, params: LocalAgentsSynthVoiceParamsResource) -> void:
	if _sfx != null:
		_sfx.register(key, params)

func sfx_keys() -> Array:
	return _sfx.keys() if _sfx != null else []

# --- Music ----------------------------------------------------------------------

## Feed a sim snapshot to the music engine. Keys: population, destruction_intensity,
## time_of_day, threat.
func set_music_mood(snapshot: Dictionary) -> void:
	if _music != null:
		_music.set_mood(snapshot)

func set_music_mode(mode: String) -> void:
	if _music != null:
		_music.set_mode(mode)

func set_music_key(key: Variant) -> void:
	if _music != null:
		_music.set_key(key)

func set_music_tempo(bpm: float) -> void:
	if _music != null:
		_music.set_tempo(bpm)

func set_music_time_signature(beats_per_bar: int) -> void:
	if _music != null:
		_music.set_time_signature(beats_per_bar)

func set_music_progression(name: String) -> void:
	if _music != null:
		_music.set_progression(name)

func set_music_auto(auto: bool) -> void:
	if _music != null:
		_music.set_auto_mode(auto)

func set_music_arrangement_enabled(enabled_flag: bool) -> void:
	if _music != null:
		_music.set_arrangement_enabled(enabled_flag)

func list_music_modes() -> Array:
	return _music.available_modes() if _music != null else []

func list_music_progressions() -> Array:
	return _music.available_progressions() if _music != null else []

func describe_music_progressions() -> Dictionary:
	return _music.describe_progressions() if _music != null else {}

func music_status() -> Dictionary:
	if _music == null:
		return {}
	return {
		"enabled": _music.is_enabled(),
		"mode": _music.current_mode(),
		"key_root": _music.current_key_root(),
		"time_signature": _music.time_signature(),
		"section": _music.current_section_label(),
	}

# --- Enable state ---------------------------------------------------------------

func set_enabled(on: bool) -> void:
	enabled = on
	_apply_enabled_state()

func set_music_enabled(on: bool) -> void:
	music_enabled = on
	_apply_enabled_state()

func set_sfx_enabled(on: bool) -> void:
	sfx_enabled = on

func _apply_enabled_state() -> void:
	if _music != null:
		_music.set_enabled(enabled and music_enabled)
