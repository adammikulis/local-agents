@tool
extends RefCounted
class_name LocalAgentSynthVoice


const SynthDsp := preload("res://addons/local_agents/audio/synth/SynthDsp.gd")

const DEFAULT_SAMPLE_RATE := 44100

func render(_params: LASynthVoiceParams, _sample_rate: int) -> PackedFloat32Array:
	push_error("NATIVE_REQUIRED: SynthVoice.render must be overridden by a concrete backend")
	return PackedFloat32Array()

## Render and wrap as a 16-bit PCM AudioStreamWAV (optionally looping).
func render_to_stream(params: LASynthVoiceParams, sample_rate: int = DEFAULT_SAMPLE_RATE, loop: bool = false) -> AudioStreamWAV:
	var buffer := render(params, sample_rate)
	return SynthDsp.to_audio_stream_wav(buffer, sample_rate, loop)

## Human-readable backend id (for introspection/debug).
func backend_id() -> String:
	return "base"
