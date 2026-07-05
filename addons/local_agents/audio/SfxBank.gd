@tool
extends RefCounted
class_name LocalAgentsSfxBank

## Renders parametric SFX presets into cached 16-bit `AudioStreamWAV` resources,
## keyed by name. Each key is synthesized once (lazily, on first request) via the
## configured `SynthVoice` backend and then reused — playback variety comes from
## per-play pitch/volume jitter at the pool, not from re-synthesis.
##
## Callers can also register custom `LocalAgentsSynthVoiceParamsResource` presets.

const SynthPresets := preload("res://addons/local_agents/audio/SynthPresets.gd")
const GdScriptSynthVoice := preload("res://addons/local_agents/audio/synth/GdScriptSynthVoice.gd")

var _voice: LocalAgentsSynthVoice = null
var _sample_rate: int = 44100
var _defs: Dictionary = {}          # key -> LocalAgentsSynthVoiceParamsResource
var _cache: Dictionary = {}         # key -> AudioStreamWAV

func configure(voice: LocalAgentsSynthVoice = null, sample_rate: int = 44100) -> void:
	_voice = voice if voice != null else GdScriptSynthVoice.new()
	_sample_rate = maxi(8000, sample_rate)
	_defs = SynthPresets.sfx_presets().duplicate()
	_cache.clear()

## Add or override a preset definition. Invalidates any cached render for that key.
func register(key: String, params: LocalAgentsSynthVoiceParamsResource) -> void:
	if key == "" or params == null:
		return
	_defs[key] = params
	_cache.erase(key)

func has_sfx(key: String) -> bool:
	return _defs.has(key)

func keys() -> Array:
	return _defs.keys()

## Return the cached AudioStreamWAV for `key`, synthesizing on first use.
## Returns null for an unknown key (caller should guard — no silent success).
func get_stream(key: String) -> AudioStreamWAV:
	if _cache.has(key):
		return _cache[key]
	if not _defs.has(key):
		push_error("AUDIO_SFX_UNKNOWN_KEY: '%s' is not a registered SFX preset" % key)
		return null
	if _voice == null:
		_voice = GdScriptSynthVoice.new()
	var params: LocalAgentsSynthVoiceParamsResource = _defs[key]
	var stream := _voice.render_to_stream(params, _sample_rate, false)
	_cache[key] = stream
	return stream

## Pre-render every registered preset (e.g. at load to avoid first-hit hitches).
func prewarm() -> void:
	for key in _defs.keys():
		get_stream(key)
