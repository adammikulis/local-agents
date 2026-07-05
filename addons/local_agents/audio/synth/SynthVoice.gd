@tool
extends RefCounted
class_name LocalAgentsSynthVoice

## Swappable synthesis backend interface.
##
## A voice turns a `LocalAgentsSynthVoiceParamsResource` into a mono float buffer
## (samples ~[-1, 1]). The default backend is `GdScriptSynthVoice`; a native /
## GodotSynth-backed voice can be dropped in later without touching SfxBank,
## MusicDirector, or AudioDirector — they only depend on this interface.
##
## Subclasses MUST override `render`. `render_to_stream` is provided for free.

const SynthDsp := preload("res://addons/local_agents/audio/synth/SynthDsp.gd")

const DEFAULT_SAMPLE_RATE := 44100

## Return a mono float buffer for `params`. Base implementation is silence.
func render(_params: LocalAgentsSynthVoiceParamsResource, _sample_rate: int) -> PackedFloat32Array:
	push_error("NATIVE_REQUIRED: SynthVoice.render must be overridden by a concrete backend")
	return PackedFloat32Array()

## Render and wrap as a 16-bit PCM AudioStreamWAV (optionally looping).
func render_to_stream(params: LocalAgentsSynthVoiceParamsResource, sample_rate: int = DEFAULT_SAMPLE_RATE, loop: bool = false) -> AudioStreamWAV:
	var buffer := render(params, sample_rate)
	return SynthDsp.to_audio_stream_wav(buffer, sample_rate, loop)

## Human-readable backend id (for introspection/debug).
func backend_id() -> String:
	return "base"
