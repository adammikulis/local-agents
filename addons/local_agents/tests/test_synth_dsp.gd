@tool
extends RefCounted

## Unit tests for the procedural-audio DSP core, the default synth voice, the SFX
## bank, and the voice pool. All headless-safe (renders into in-memory buffers;
## asserts on buffer contents, never on audible output).

const SynthDsp := preload("res://addons/local_agents/audio/synth/SynthDsp.gd")
const GdScriptSynthVoice := preload("res://addons/local_agents/audio/synth/GdScriptSynthVoice.gd")
const SynthPresets := preload("res://addons/local_agents/audio/SynthPresets.gd")
const SfxBank := preload("res://addons/local_agents/audio/SfxBank.gd")
const AudioVoicePool := preload("res://addons/local_agents/audio/AudioVoicePool.gd")
const AudioDirector := preload("res://addons/local_agents/audio/AudioDirector.gd")

const SR := 22050

func run_test(tree: SceneTree) -> bool:
	if not _test_oscillators():
		return false
	if not _test_envelope():
		return false
	if not _test_filter():
		return false
	if not _test_pcm_export():
		return false
	if not _test_voice_and_bank():
		return false
	if not _test_voice_pool(tree):
		return false
	if not _test_audio_director(tree):
		return false
	return true

func _test_oscillators() -> bool:
	var buf := SynthDsp.render_osc(220.0, 220.0, 0.05, SR, 0, 0.5)
	if buf.size() != int(round(0.05 * SR)):
		push_error("render_osc length wrong: %d" % buf.size())
		return false
	for s in buf:
		if s < -1.001 or s > 1.001:
			push_error("oscillator out of range: %f" % s)
			return false
	if SynthDsp.rms(buf) <= 0.01:
		push_error("sine oscillator is silent")
		return false
	return true

func _test_envelope() -> bool:
	var env := SynthDsp.adsr_envelope(SR, SR, 0.1, 0.1, 0.5, 0.2)
	if env.size() != SR:
		push_error("envelope wrong length")
		return false
	if env[0] > 0.2:
		push_error("attack should start near zero, got %f" % env[0])
		return false
	if env[env.size() - 1] > 0.02:
		push_error("release should end near zero, got %f" % env[env.size() - 1])
		return false
	var peak := 0.0
	for v in env:
		peak = maxf(peak, v)
	if peak < 0.9:
		push_error("envelope should reach ~1.0, peak=%f" % peak)
		return false
	return true

func _test_filter() -> bool:
	# A bright tone lowpassed well below its frequency should lose energy.
	var tone := SynthDsp.render_osc(6000.0, 6000.0, 0.1, SR, 0, 0.5)
	var before := SynthDsp.rms(tone)
	SynthDsp.biquad_lowpass(tone, SR, 300.0, 0.707)
	var after := SynthDsp.rms(tone)
	if after >= before * 0.6:
		push_error("lowpass failed to attenuate high tone: %f -> %f" % [before, after])
		return false
	return true

func _test_pcm_export() -> bool:
	var buf := SynthDsp.render_osc(440.0, 440.0, 0.02, SR, 0, 0.5)
	var wav := SynthDsp.to_audio_stream_wav(buf, SR, false)
	if wav == null or wav.format != AudioStreamWAV.FORMAT_16_BITS:
		push_error("wav export format wrong")
		return false
	if wav.mix_rate != SR:
		push_error("wav mix_rate wrong: %d" % wav.mix_rate)
		return false
	if wav.data.size() != buf.size() * 2:
		push_error("wav data size mismatch: %d vs %d" % [wav.data.size(), buf.size() * 2])
		return false
	var looped := SynthDsp.to_audio_stream_wav(buf, SR, true)
	if looped.loop_mode != AudioStreamWAV.LOOP_FORWARD:
		push_error("looped wav should loop forward")
		return false
	return true

func _test_voice_and_bank() -> bool:
	var voice := GdScriptSynthVoice.new()
	# Deterministic: same params + seed → identical render.
	var params := SynthPresets.get_preset("impact_soft")
	var a := voice.render(params, SR)
	var b := voice.render(params, SR)
	if a != b:
		push_error("voice render not deterministic for a fixed seed")
		return false
	if SynthDsp.rms(a) <= 0.01:
		push_error("impact_soft rendered silent")
		return false

	var bank := SfxBank.new()
	bank.configure(voice, SR)
	for key in bank.keys():
		var stream: AudioStreamWAV = bank.get_stream(key)
		if stream == null or stream.data.is_empty():
			push_error("SFX '%s' produced no data" % key)
			return false
	# Unknown key must fail loudly (no silent success).
	if bank.get_stream("does_not_exist") != null:
		push_error("unknown SFX key should return null")
		return false
	return true

func _test_voice_pool(tree: SceneTree) -> bool:
	var pool := AudioVoicePool.new()
	tree.root.add_child(pool)
	pool.configure(4, 2)
	var voice := GdScriptSynthVoice.new()
	var stream := voice.render_to_stream(SynthPresets.get_preset("ui_click"), SR, false)
	var first := pool.play_positional(stream, Vector3.ZERO, 1.0, 0.0, "click")
	var second := pool.play_positional(stream, Vector3.ZERO, 1.0, 0.0, "click")
	pool.queue_free()
	if not first:
		push_error("pool first play should succeed")
		return false
	if second:
		push_error("pool second play with same cooldown key should be suppressed")
		return false
	return true

func _test_audio_director(tree: SceneTree) -> bool:
	var director := AudioDirector.new()
	tree.root.add_child(director)
	director.configure(null, SR, 99)
	var ok_positional := director.play_sfx("impact_hard", Vector3(1, 0, 1))
	var ok_ui := director.play_sfx("ui_click")
	var keys := director.sfx_keys()
	director.queue_free()
	if not ok_positional:
		push_error("director positional SFX failed")
		return false
	if not ok_ui:
		push_error("director UI SFX failed")
		return false
	if keys.is_empty():
		push_error("director should expose SFX keys")
		return false
	return true
