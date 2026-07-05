@tool
extends RefCounted
class_name LocalAgentsSynthDsp

## Pure, stateless DSP primitives for procedural audio synthesis.
##
## Everything here operates on mono float buffers (`PackedFloat32Array`, samples in
## roughly [-1, 1]) so it is trivially unit-testable without audio hardware. Higher
## layers (SynthVoice / SfxBank / MusicDirector) compose these into cached
## `AudioStreamWAV` resources. No node, no engine state, no global RNG.

const TAU_F := TAU

# --- Oscillators (phase is a running value in turns; only the fractional part matters) ---

static func osc_sine(phase: float) -> float:
	return sin(phase * TAU_F)

static func osc_saw(phase: float) -> float:
	var t := fposmod(phase, 1.0)
	return t * 2.0 - 1.0

static func osc_square(phase: float, duty: float = 0.5) -> float:
	var t := fposmod(phase, 1.0)
	return 1.0 if t < clampf(duty, 0.01, 0.99) else -1.0

static func osc_triangle(phase: float) -> float:
	var t := fposmod(phase, 1.0)
	return 4.0 * absf(t - 0.5) - 1.0

## Waveform selector matching SynthVoiceParamsResource.Waveform.
## 0=sine 1=saw 2=square 3=triangle.
static func osc(waveform: int, phase: float, duty: float = 0.5) -> float:
	match waveform:
		1:
			return osc_saw(phase)
		2:
			return osc_square(phase, duty)
		3:
			return osc_triangle(phase)
		_:
			return osc_sine(phase)

## Render a pitched oscillator with an optional linear pitch glide from
## `freq_start` to `freq_end` across the buffer.
static func render_osc(
	freq_start: float,
	freq_end: float,
	duration_s: float,
	sample_rate: int,
	waveform: int,
	duty: float = 0.5
) -> PackedFloat32Array:
	var n := maxi(1, int(round(duration_s * float(sample_rate))))
	var out := PackedFloat32Array()
	out.resize(n)
	var phase := 0.0
	var inv_sr := 1.0 / float(sample_rate)
	for i in n:
		var t := float(i) / float(n)
		var freq := lerpf(freq_start, freq_end, t)
		out[i] = osc(waveform, phase, duty)
		phase += freq * inv_sr
	return out

# --- Noise ---

## White noise buffer driven by a caller-owned seeded RNG (keeps determinism).
static func render_white_noise(n_samples: int, rng: RandomNumberGenerator) -> PackedFloat32Array:
	var n := maxi(1, n_samples)
	var out := PackedFloat32Array()
	out.resize(n)
	for i in n:
		out[i] = rng.randf_range(-1.0, 1.0)
	return out

## Pink (1/f) noise via Paul Kellet's economy filter. Warmer, more natural than
## white noise — the backbone of the naturalistic impact/wind character.
static func render_pink_noise(n_samples: int, rng: RandomNumberGenerator) -> PackedFloat32Array:
	var n := maxi(1, n_samples)
	var out := PackedFloat32Array()
	out.resize(n)
	var b0 := 0.0
	var b1 := 0.0
	var b2 := 0.0
	var b3 := 0.0
	var b4 := 0.0
	var b5 := 0.0
	var b6 := 0.0
	for i in n:
		var white := rng.randf_range(-1.0, 1.0)
		b0 = 0.99886 * b0 + white * 0.0555179
		b1 = 0.99332 * b1 + white * 0.0750759
		b2 = 0.96900 * b2 + white * 0.1538520
		b3 = 0.86650 * b3 + white * 0.3104856
		b4 = 0.55000 * b4 + white * 0.5329522
		b5 = -0.7616 * b5 - white * 0.0168980
		var pink := b0 + b1 + b2 + b3 + b4 + b5 + b6 + white * 0.5362
		b6 = white * 0.115926
		out[i] = pink * 0.11
	return out

# --- Envelope ---

## Build an ADSR gain curve of `n_samples`. `sustain` is the sustain level (0..1);
## attack/decay/release are seconds. The sustain segment fills whatever time is left
## between the decay end and the release start.
static func adsr_envelope(
	n_samples: int,
	sample_rate: int,
	attack_s: float,
	decay_s: float,
	sustain: float,
	release_s: float
) -> PackedFloat32Array:
	var n := maxi(1, n_samples)
	var env := PackedFloat32Array()
	env.resize(n)
	var sr := float(sample_rate)
	var a := maxi(0, int(round(maxf(0.0, attack_s) * sr)))
	var d := maxi(0, int(round(maxf(0.0, decay_s) * sr)))
	var r := maxi(0, int(round(maxf(0.0, release_s) * sr)))
	var sus := clampf(sustain, 0.0, 1.0)
	# Clamp segments so attack+decay+release never exceed the buffer.
	if a + d + r > n:
		var scale := float(n) / float(maxi(1, a + d + r))
		a = int(a * scale)
		d = int(d * scale)
		r = int(r * scale)
	var sustain_start := a + d
	var release_start := n - r
	for i in n:
		var g := 0.0
		if i < a and a > 0:
			g = float(i) / float(a)
		elif i < sustain_start and d > 0:
			g = lerpf(1.0, sus, float(i - a) / float(d))
		elif i < release_start:
			g = sus
		elif r > 0:
			g = lerpf(sus, 0.0, float(i - release_start) / float(r))
		env[i] = clampf(g, 0.0, 1.0)
	return env

# --- Biquad filters (RBJ cookbook) ---

## Process `buffer` in place through a biquad given raw (un-normalized) coefficients.
static func _biquad_process(
	buffer: PackedFloat32Array,
	b0: float, b1: float, b2: float,
	a0: float, a1: float, a2: float
) -> void:
	if a0 == 0.0:
		return
	var nb0 := b0 / a0
	var nb1 := b1 / a0
	var nb2 := b2 / a0
	var na1 := a1 / a0
	var na2 := a2 / a0
	var x1 := 0.0
	var x2 := 0.0
	var y1 := 0.0
	var y2 := 0.0
	for i in buffer.size():
		var x0 := buffer[i]
		var y0 := nb0 * x0 + nb1 * x1 + nb2 * x2 - na1 * y1 - na2 * y2
		buffer[i] = y0
		x2 = x1
		x1 = x0
		y2 = y1
		y1 = y0

static func biquad_lowpass(buffer: PackedFloat32Array, sample_rate: int, cutoff: float, q: float = 0.707) -> void:
	var w0 := TAU_F * clampf(cutoff, 1.0, float(sample_rate) * 0.49) / float(sample_rate)
	var cw := cos(w0)
	var alpha := sin(w0) / (2.0 * maxf(0.0001, q))
	_biquad_process(buffer, (1.0 - cw) * 0.5, 1.0 - cw, (1.0 - cw) * 0.5, 1.0 + alpha, -2.0 * cw, 1.0 - alpha)

static func biquad_highpass(buffer: PackedFloat32Array, sample_rate: int, cutoff: float, q: float = 0.707) -> void:
	var w0 := TAU_F * clampf(cutoff, 1.0, float(sample_rate) * 0.49) / float(sample_rate)
	var cw := cos(w0)
	var alpha := sin(w0) / (2.0 * maxf(0.0001, q))
	_biquad_process(buffer, (1.0 + cw) * 0.5, -(1.0 + cw), (1.0 + cw) * 0.5, 1.0 + alpha, -2.0 * cw, 1.0 - alpha)

static func biquad_bandpass(buffer: PackedFloat32Array, sample_rate: int, cutoff: float, q: float = 1.0) -> void:
	var w0 := TAU_F * clampf(cutoff, 1.0, float(sample_rate) * 0.49) / float(sample_rate)
	var cw := cos(w0)
	var alpha := sin(w0) / (2.0 * maxf(0.0001, q))
	_biquad_process(buffer, alpha, 0.0, -alpha, 1.0 + alpha, -2.0 * cw, 1.0 - alpha)

## Filter-type selector matching SynthVoiceParamsResource.FilterType.
## 0=none 1=lowpass 2=highpass 3=bandpass.
static func apply_filter(buffer: PackedFloat32Array, sample_rate: int, filter_type: int, cutoff: float, q: float) -> void:
	match filter_type:
		1:
			biquad_lowpass(buffer, sample_rate, cutoff, q)
		2:
			biquad_highpass(buffer, sample_rate, cutoff, q)
		3:
			biquad_bandpass(buffer, sample_rate, cutoff, q)
		_:
			pass

# --- Buffer utilities ---

## In-place per-sample multiply by a same-length gain curve (e.g. an envelope).
static func apply_gain_curve(buffer: PackedFloat32Array, curve: PackedFloat32Array) -> void:
	var n := mini(buffer.size(), curve.size())
	for i in n:
		buffer[i] = buffer[i] * curve[i]

static func scale(buffer: PackedFloat32Array, gain: float) -> void:
	for i in buffer.size():
		buffer[i] = buffer[i] * gain

## Mix `src` into `dst` (dst modified in place) with `gain`. Buffers may differ in
## length; overlap only.
static func mix_into(dst: PackedFloat32Array, src: PackedFloat32Array, gain: float) -> void:
	var n := mini(dst.size(), src.size())
	for i in n:
		dst[i] = dst[i] + src[i] * gain

## Peak-normalize to `peak` (does nothing on silence).
static func normalize(buffer: PackedFloat32Array, peak: float = 0.9) -> void:
	var m := 0.0
	for i in buffer.size():
		m = maxf(m, absf(buffer[i]))
	if m <= 0.00001:
		return
	scale(buffer, peak / m)

## Hard-clip to [-1, 1] to guarantee valid PCM.
static func clip(buffer: PackedFloat32Array) -> void:
	for i in buffer.size():
		buffer[i] = clampf(buffer[i], -1.0, 1.0)

static func rms(buffer: PackedFloat32Array) -> float:
	if buffer.is_empty():
		return 0.0
	var acc := 0.0
	for i in buffer.size():
		acc += buffer[i] * buffer[i]
	return sqrt(acc / float(buffer.size()))

# --- PCM export ---

## Convert a mono float buffer to a 16-bit PCM `AudioStreamWAV`. When `loop` is
## true the whole buffer loops forward (used for sustained music drones).
static func to_audio_stream_wav(buffer: PackedFloat32Array, sample_rate: int, loop: bool = false) -> AudioStreamWAV:
	var n := buffer.size()
	var bytes := PackedByteArray()
	bytes.resize(n * 2)
	for i in n:
		var s := int(round(clampf(buffer[i], -1.0, 1.0) * 32767.0))
		# little-endian signed 16-bit
		var u := s & 0xFFFF
		bytes[i * 2] = u & 0xFF
		bytes[i * 2 + 1] = (u >> 8) & 0xFF
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = sample_rate
	wav.stereo = false
	wav.data = bytes
	if loop and n > 1:
		wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
		wav.loop_begin = 0
		wav.loop_end = n - 1
	else:
		wav.loop_mode = AudioStreamWAV.LOOP_DISABLED
	return wav
