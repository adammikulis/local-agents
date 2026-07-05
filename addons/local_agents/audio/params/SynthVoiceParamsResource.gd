@tool
extends Resource
class_name LocalAgentsSynthVoiceParamsResource

## Typed parameters describing one synthesized voice/sound. Fully inspector-editable
## and serializable, so presets can live as `.tres` files or be built in code. A
## `SynthVoice` turns this into a mono float buffer; `SynthDsp.to_audio_stream_wav`
## turns that into a cached `AudioStreamWAV`.

enum Waveform { SINE, SAW, SQUARE, TRIANGLE }
enum FilterType { NONE, LOWPASS, HIGHPASS, BANDPASS }
enum NoiseType { WHITE, PINK }

@export_group("Tone")
## Tonal oscillator waveform (ignored when noise_mix == 1.0).
@export var waveform: Waveform = Waveform.SINE
## Starting pitch in Hz.
@export var frequency: float = 220.0
## Ending pitch in Hz — differs from `frequency` to glide/sweep across the sound.
@export var frequency_end: float = 220.0
## Square-wave duty cycle (only used for SQUARE).
@export_range(0.02, 0.98, 0.01) var duty: float = 0.5
## Overall length in seconds.
@export_range(0.02, 8.0, 0.01) var duration: float = 0.4
## Peak amplitude after normalization (0..1).
@export_range(0.0, 1.0, 0.01) var amplitude: float = 0.9

@export_group("Noise")
## Blend between tonal oscillator (0.0) and noise (1.0). Naturalistic impacts sit high.
@export_range(0.0, 1.0, 0.01) var noise_mix: float = 0.0
@export var noise_type: NoiseType = NoiseType.PINK

@export_group("Envelope (ADSR, seconds)")
@export_range(0.0, 2.0, 0.001) var attack: float = 0.005
@export_range(0.0, 2.0, 0.001) var decay: float = 0.08
@export_range(0.0, 1.0, 0.01) var sustain: float = 0.0
@export_range(0.0, 4.0, 0.001) var release: float = 0.12

@export_group("Filter")
@export var filter_type: FilterType = FilterType.NONE
@export_range(20.0, 20000.0, 1.0) var filter_cutoff: float = 8000.0
@export_range(0.1, 12.0, 0.1) var filter_q: float = 0.707

@export_group("Determinism")
## Seed for any noise in this voice. Fixed seed → identical render (testable).
@export var seed: int = 0

## Convenience constructor for code-defined presets.
static func make(fields: Dictionary) -> LocalAgentsSynthVoiceParamsResource:
	var p := LocalAgentsSynthVoiceParamsResource.new()
	for key in fields:
		p.set(key, fields[key])
	return p

func duplicate_params() -> LocalAgentsSynthVoiceParamsResource:
	return duplicate(true) as LocalAgentsSynthVoiceParamsResource
