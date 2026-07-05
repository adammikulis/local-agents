@tool
extends "res://addons/local_agents/audio/synth/SynthVoice.gd"
class_name LocalAgentsGdScriptSynthVoice

## Default, dependency-free synthesis backend built on SynthDsp.
##
## Signal chain: (oscillator ⊕ noise) → ADSR envelope → biquad filter →
## normalize → clip. Deterministic given the params' `seed`.

const Params := preload("res://addons/local_agents/audio/params/SynthVoiceParamsResource.gd")

func render(params: LocalAgentsSynthVoiceParamsResource, sample_rate: int) -> PackedFloat32Array:
	if params == null:
		return PackedFloat32Array()
	var sr := maxi(8000, sample_rate)
	var n := maxi(1, int(round(maxf(0.01, params.duration) * float(sr))))

	# Tonal component.
	var tone := SynthDsp.render_osc(
		maxf(1.0, params.frequency),
		maxf(1.0, params.frequency_end),
		params.duration,
		sr,
		int(params.waveform),
		params.duty
	)

	# Noise component (seeded, deterministic).
	var noise_mix := clampf(params.noise_mix, 0.0, 1.0)
	var buffer := PackedFloat32Array()
	if noise_mix <= 0.0:
		buffer = tone
	else:
		var rng := RandomNumberGenerator.new()
		rng.seed = params.seed
		var noise: PackedFloat32Array
		if int(params.noise_type) == Params.NoiseType.WHITE:
			noise = SynthDsp.render_white_noise(n, rng)
		else:
			noise = SynthDsp.render_pink_noise(n, rng)
		buffer = PackedFloat32Array()
		buffer.resize(n)
		for i in n:
			var tone_s := tone[i] if i < tone.size() else 0.0
			var noise_s := noise[i] if i < noise.size() else 0.0
			buffer[i] = lerpf(tone_s, noise_s, noise_mix)

	# Envelope.
	var env := SynthDsp.adsr_envelope(buffer.size(), sr, params.attack, params.decay, params.sustain, params.release)
	SynthDsp.apply_gain_curve(buffer, env)

	# Filter.
	SynthDsp.apply_filter(buffer, sr, int(params.filter_type), params.filter_cutoff, params.filter_q)

	# Level.
	SynthDsp.normalize(buffer, clampf(params.amplitude, 0.0, 1.0))
	SynthDsp.clip(buffer)
	return buffer

func backend_id() -> String:
	return "gdscript"
