@tool
extends Node
class_name LocalAgentsMusicDirector

## Multi-layer generative music engine with long-form song structure.
##
## Layers (all synthesized at runtime via the swappable SynthVoice):
##   • pad    — sustained chord tones (harmonic bed), crossfaded on chord change
##   • bass   — chord root/fifth on downbeats
##   • arp    — chord-tone arpeggio gated by density
##   • melody — sparse in-mode motif with voice-leading toward chord tones
##   • perc   — soft filtered-noise backbeat when energetic
##
## Harmony source: "generative" (ChordProgressionPlanner over any mode, e.g.
## phrygian_dominant) or "library" (a named real-world progression). A SongArranger
## walks a section form (intro/verse/chorus/bridge/outro) so the music EVOLVES —
## mid-song key modulations, mode changes, time-signature changes, tempo shifts, and
## fresh progressions per section — rather than looping four chords forever.
##
## Pickable at runtime: set_mode(), set_key(), set_tempo(), set_time_signature(),
## set_progression(), set_arrangement_enabled(). Presentation-only + dedicated seeded
## RNG → never perturbs sim determinism, never replays on rewind. set_mood() reacts
## to live sim state.

const SynthDsp := preload("res://addons/local_agents/audio/synth/SynthDsp.gd")
const GdScriptSynthVoice := preload("res://addons/local_agents/audio/synth/GdScriptSynthVoice.gd")
const SynthPresets := preload("res://addons/local_agents/audio/SynthPresets.gd")
const Theory := preload("res://addons/local_agents/audio/music/MusicTheory.gd")
const Planner := preload("res://addons/local_agents/audio/music/ChordProgressionPlanner.gd")
const Library := preload("res://addons/local_agents/audio/music/ChordProgressionLibrary.gd")
const Arranger := preload("res://addons/local_agents/audio/music/SongArranger.gd")

const STEPS_PER_BEAT := 4
const KEY_MIN := 33   # A1
const KEY_MAX := 57   # A3

var _voice: LocalAgentsSynthVoice = null
var _sample_rate: int = 44100
var _rng := RandomNumberGenerator.new()
var _planner := Planner.new()
var _arranger := Arranger.new()
var _music_bus: StringName = &"Music"
var _enabled: bool = false

# Harmony / key / meter / tempo.
var _harmony_source: String = "generative"
var _mode: String = "aeolian"
var _mode_locked: bool = false
var _key_root: int = 45
var _base_tempo: float = 84.0
var _tempo_bpm: float = 84.0
var _beats_per_bar: int = 4
var _progression_name: String = ""
var _progression: Array = []
var _bars_per_chord: int = 1

# Arrangement.
var _arrangement_enabled: bool = true
var _section: Dictionary = {}
var _section_bars_left: int = 4
var _section_energy: float = 0.4
var _section_density: float = 0.4
var _section_register: int = 0

# Clock.
var _step_accum: float = 0.0
var _step_counter: int = 0
var _step_in_bar: int = 0
var _bar_in_section: int = 0
var _chord_index: int = 0

# Mood (from sim).
var _mood := {"density": 0.4, "brightness": 0.5, "tension": 0.3, "pad_gain": 0.6, "energy": 0.4}
var _last_melody_midi: int = -1

# Players + caches.
var _pad_players: Array[AudioStreamPlayer] = []
var _pad_idx: int = 0
var _bass_players: Array[AudioStreamPlayer] = []
var _arp_players: Array[AudioStreamPlayer] = []
var _melody_players: Array[AudioStreamPlayer] = []
var _perc_players: Array[AudioStreamPlayer] = []
var _note_cache: Dictionary = {}
var _chord_cache: Dictionary = {}

func configure(voice: LocalAgentsSynthVoice = null, sample_rate: int = 44100, seed: int = 1337, music_bus: StringName = &"Music") -> void:
	_voice = voice if voice != null else GdScriptSynthVoice.new()
	_sample_rate = maxi(8000, sample_rate)
	_rng.seed = seed
	_music_bus = music_bus
	_build_players()
	_arranger.reset()
	_base_tempo = _tempo_bpm
	_begin_section(_arranger.next_section(_rng, not _mode_locked, _arrangement_enabled))

## Re-seed the generative RNG in place (no player rebuild) so each session's music evolves
## differently. Feeds a fresh section from the new seed. Cheap — just reseats the sequencer.
func reseed(seed: int) -> void:
	_rng.seed = seed
	_arranger.reset()
	_begin_section(_arranger.next_section(_rng, not _mode_locked, _arrangement_enabled))

func _steps_per_bar() -> int:
	return STEPS_PER_BEAT * maxi(2, _beats_per_bar)

# --- Public control -------------------------------------------------------------

func set_enabled(enabled: bool) -> void:
	_enabled = enabled
	if enabled:
		_trigger_chord(true)
	else:
		for p in _all_players():
			if is_instance_valid(p) and p.playing:
				p.stop()

func is_enabled() -> bool:
	return _enabled

## Pick a mode (e.g. "phrygian_dominant"); switches to generative harmony and locks
## the mode against auto/arranger selection.
func set_mode(mode: String) -> void:
	if not Theory.has_mode(mode):
		push_error("AUDIO_MUSIC_UNKNOWN_MODE: '%s'" % mode)
		return
	_mode = mode
	_mode_locked = true
	_harmony_source = "generative"
	_build_section_progression(_section)

func available_modes() -> Array:
	return Theory.mode_names()

func set_key(key: Variant) -> void:
	if key is String:
		var m := Theory.name_to_midi(key)
		if m >= 0:
			_key_root = _clamp_key(m)
	elif key is int or key is float:
		_key_root = _clamp_key(int(key))
	_build_section_progression(_section)

func set_tempo(bpm: float) -> void:
	_base_tempo = clampf(bpm, 30.0, 220.0)
	_tempo_bpm = _base_tempo * float(_section.get("tempo_scale", 1.0))

## Set the meter (beats per bar). Applies immediately; the arranger may change it
## again at later section boundaries unless arrangement is disabled.
func set_time_signature(beats_per_bar: int) -> void:
	_beats_per_bar = clampi(beats_per_bar, 2, 12)
	_step_in_bar = mini(_step_in_bar, _steps_per_bar() - 1)

func time_signature() -> int:
	return _beats_per_bar

func set_progression(name: String) -> void:
	if not Library.has_progression(name):
		push_error("AUDIO_MUSIC_UNKNOWN_PROGRESSION: '%s'" % name)
		return
	_progression_name = name
	_harmony_source = "library"
	var entry := Library.get_entry(name)
	if not _mode_locked:
		_mode = "ionian" if String(entry.get("key", "major")) == "major" else "aeolian"
	_build_section_progression(_section)

func available_progressions() -> Array:
	return Library.names()

func describe_progressions() -> Dictionary:
	return Library.describe_all()

func set_auto_mode(auto: bool) -> void:
	_mode_locked = not auto
	if auto:
		_harmony_source = "generative"

## Enable/disable long-form evolution (sections, modulation, meter/tempo changes).
func set_arrangement_enabled(enabled: bool) -> void:
	_arrangement_enabled = enabled

func current_section_label() -> String:
	return String(_section.get("label", ""))

func set_mood(snapshot: Dictionary) -> void:
	var population := int(snapshot.get("population", 0))
	var destruction := clampf(float(snapshot.get("destruction_intensity", 0.0)), 0.0, 1.0)
	var threat := clampf(float(snapshot.get("threat", destruction)), 0.0, 1.0)
	var tod := clampf(float(snapshot.get("time_of_day", 0.35)), 0.0, 1.0)
	var day_factor := 0.5 - 0.5 * cos(tod * TAU)
	_mood["density"] = clampf(0.2 + minf(1.0, float(population) / 24.0) * 0.5 + destruction * 0.25, 0.05, 1.0)
	_mood["brightness"] = clampf(0.25 + day_factor * 0.6 - threat * 0.2, 0.0, 1.0)
	_mood["tension"] = clampf(0.2 + threat * 0.7, 0.0, 1.0)
	_mood["energy"] = clampf(0.2 + destruction * 0.6 + minf(1.0, float(population) / 30.0) * 0.3, 0.0, 1.0)
	_mood["pad_gain"] = clampf(0.45 + day_factor * 0.25, 0.2, 0.85)
	# When the arranger is off, mood may drive the base tempo and mode directly.
	if not _arrangement_enabled:
		set_tempo(lerpf(70.0, 104.0, _mood["energy"]))
		if not _mode_locked and _harmony_source == "generative":
			var picked := _auto_mode(day_factor, threat)
			if picked != _mode:
				_mode = picked
				_build_section_progression(_section)

func _auto_mode(day_factor: float, threat: float) -> String:
	if threat > 0.7:
		return "phrygian_dominant"
	if threat > 0.45:
		return "harmonic_minor"
	if day_factor > 0.66:
		return "lydian"
	if day_factor > 0.45:
		return "ionian"
	if day_factor > 0.25:
		return "dorian"
	return "aeolian"

# --- Introspection --------------------------------------------------------------

func current_chord() -> Array:
	if _progression.is_empty():
		return []
	return _progression[_chord_index % _progression.size()]

func progression_midis() -> Array:
	return _progression

func current_mode() -> String:
	return _mode

func current_key_root() -> int:
	return _key_root

# --- Clock ----------------------------------------------------------------------

func _process(delta: float) -> void:
	if not _enabled or delta <= 0.0 or _progression.is_empty():
		return
	var seconds_per_step := 60.0 / maxf(1.0, _tempo_bpm) / float(STEPS_PER_BEAT)
	_step_accum += delta
	var guard := 0
	while _step_accum >= seconds_per_step and guard < 96:
		_step_accum -= seconds_per_step
		_on_step()
		_step_in_bar += 1
		if _step_in_bar >= _steps_per_bar():
			_step_in_bar = 0
			_on_bar_end()
		guard += 1

func _on_step() -> void:
	var sib := _step_in_bar
	var beat := sib / STEPS_PER_BEAT
	var eff_density := _eff_density()
	var eff_energy := _eff_energy()

	if sib == 0:
		var chords := _progression.size()
		_chord_index = (_bar_in_section / maxi(1, _bars_per_chord)) % maxi(1, chords)
		_trigger_chord(false)
		_trigger_bass(0)
	if sib == STEPS_PER_BEAT * 2 and _beats_per_bar >= 3:
		_trigger_bass(1)

	if _rng.randf() < eff_density * 0.8:
		_trigger_arp(_step_counter)
	if (beat == 1 or beat == 3) and sib % STEPS_PER_BEAT == 0:
		if _rng.randf() < eff_energy:
			_trigger_perc()
	if sib % STEPS_PER_BEAT == 0 and _rng.randf() < eff_density * 0.4:
		_trigger_melody()

	_step_counter += 1

func _on_bar_end() -> void:
	_bar_in_section += 1
	_section_bars_left -= 1
	if _section_bars_left <= 0:
		if _arrangement_enabled:
			_begin_section(_arranger.next_section(_rng, not _mode_locked, true))
		else:
			# No long-form: still refresh a generative progression for variety.
			_bar_in_section = 0
			if _harmony_source == "generative":
				_build_section_progression(_section)
			_section_bars_left = 4

# --- Sections -------------------------------------------------------------------

func _begin_section(section: Dictionary) -> void:
	_section = section
	_bar_in_section = 0
	_section_bars_left = maxi(1, int(section.get("bars", 4)))
	_section_energy = float(section.get("energy", 0.4))
	_section_density = float(section.get("density", 0.4))
	_section_register = int(section.get("register", 0))

	var modulation := int(section.get("key_modulation", 0))
	if modulation != 0:
		_key_root = _clamp_key(_key_root + modulation)
	var new_mode := String(section.get("mode", ""))
	if new_mode != "" and not _mode_locked and Theory.has_mode(new_mode):
		_mode = new_mode
	var meter := int(section.get("beats_per_bar", 0))
	if meter > 0:
		_beats_per_bar = clampi(meter, 2, 12)
	_tempo_bpm = clampf(_base_tempo * float(section.get("tempo_scale", 1.0)), 30.0, 220.0)

	_build_section_progression(section)

func _build_section_progression(section: Dictionary) -> void:
	var contrast := bool(section.get("contrast", false))
	if contrast:
		# Bridge: contrasting generative progression regardless of the base source.
		_progression = _planner.plan_midis(_key_root, _mode, _rng.randi_range(4, 6), _rng, _mood)
		_bars_per_chord = 1
	elif _harmony_source == "library" and _progression_name != "":
		_progression = Library.resolve(_progression_name, _key_root, 0)
		_bars_per_chord = 1
	else:
		var length := _rng.randi_range(3, 6)
		_progression = _planner.plan_midis(_key_root, _mode, length, _rng, _mood)
		_bars_per_chord = 2 if _tempo_bpm > 120.0 else 1
	if _progression.is_empty():
		# Safety: never leave the engine with no harmony.
		_progression = _planner.plan_midis(_key_root, "aeolian", 4, _rng, _mood)
	_chord_index = 0

func _eff_density() -> float:
	return clampf(float(_mood["density"]) * 0.5 + _section_density * 0.6, 0.0, 1.0)

func _eff_energy() -> float:
	return clampf(float(_mood["energy"]) * 0.5 + _section_energy * 0.6, 0.0, 1.0)

# --- Layer triggers -------------------------------------------------------------

func _trigger_chord(_force: bool) -> void:
	var chord := current_chord()
	if chord.is_empty():
		return
	var stream := _chord_stream(chord)
	if stream == null or _pad_players.is_empty():
		return
	var player := _pad_players[_pad_idx]
	_pad_idx = (_pad_idx + 1) % _pad_players.size()
	for other in _pad_players:
		if other != player and is_instance_valid(other) and other.playing:
			other.volume_db = linear_to_db(0.0001)
	player.stream = stream
	player.volume_db = linear_to_db(clampf(float(_mood["pad_gain"]), 0.05, 1.0))
	player.play()

func _trigger_bass(which: int) -> void:
	var chord := current_chord()
	if chord.is_empty() or _bass_players.is_empty():
		return
	var root := int(chord[0]) - 12
	if which == 1 and chord.size() >= 3:
		root = int(chord[2]) - 12
	var p := _bass_players[which % _bass_players.size()]
	p.stream = _note_stream("bass", root)
	p.volume_db = linear_to_db(clampf(0.5 + _eff_energy() * 0.2, 0.1, 1.0))
	p.play()

func _trigger_arp(step: int) -> void:
	var chord := current_chord()
	if chord.is_empty() or _arp_players.is_empty():
		return
	var tone := int(chord[step % chord.size()])
	tone += 12 * (int(round(clampf(float(_mood["brightness"]), 0.0, 1.0))) + _section_register)
	var p := _arp_players[step % _arp_players.size()]
	p.stream = _note_stream("pluck", tone)
	p.volume_db = linear_to_db(clampf(0.3 + _eff_density() * 0.25, 0.05, 1.0))
	p.play()

func _trigger_perc() -> void:
	if _perc_players.is_empty():
		return
	var p := _perc_players[_rng.randi_range(0, _perc_players.size() - 1)]
	p.stream = _note_stream("perc_tick", 60)
	p.pitch_scale = _rng.randf_range(0.92, 1.12)
	p.volume_db = linear_to_db(clampf(0.25 + _eff_energy() * 0.2, 0.05, 0.8))
	p.play()

func _trigger_melody() -> void:
	if _melody_players.is_empty():
		return
	var midi := _next_melody_note()
	var voice_name := "bell" if float(_mood["brightness"]) > 0.45 else "marimba"
	var p := _melody_players[_rng.randi_range(0, _melody_players.size() - 1)]
	p.stream = _note_stream(voice_name, midi)
	p.volume_db = linear_to_db(clampf(0.4 + _eff_density() * 0.25, 0.05, 1.0))
	p.play()

func _next_melody_note() -> int:
	var chord := current_chord()
	var brightness := clampf(float(_mood["brightness"]), 0.0, 1.0)
	var target := _key_root + 24 + int(round(brightness * 12.0)) + 12 * _section_register
	if _last_melody_midi >= 0:
		target = _last_melody_midi + _rng.randi_range(-3, 3)
	elif not chord.is_empty():
		target = int(chord[_rng.randi_range(0, chord.size() - 1)]) + 12
	var snapped := Theory.snap_to_mode(target, _key_root, _mode)
	if not chord.is_empty() and _rng.randf() < 0.35:
		snapped = int(chord[_rng.randi_range(0, chord.size() - 1)]) + 12
	_last_melody_midi = snapped
	return snapped

# --- Rendering ------------------------------------------------------------------

func _chord_stream(chord: Array) -> AudioStreamWAV:
	var sorted := chord.duplicate()
	sorted.sort()
	var sig := "pad:" + ",".join(PackedStringArray(sorted.map(func(m): return str(m))))
	if _chord_cache.has(sig):
		return _chord_cache[sig]
	var presets := SynthPresets.music_voice_presets()
	var base: LocalAgentsSynthVoiceParamsResource = presets.get("pad_warm")
	if base == null:
		return null
	var mix := PackedFloat32Array()
	var gain := 1.0 / sqrt(float(maxi(1, chord.size())))
	for note in chord:
		var params: LocalAgentsSynthVoiceParamsResource = base.duplicate_params()
		var freq := Theory.midi_to_hz(int(note))
		params.frequency = freq
		params.frequency_end = freq
		var buf := _voice.render(params, _sample_rate)
		if mix.is_empty():
			mix.resize(buf.size())
		SynthDsp.mix_into(mix, buf, gain)
	SynthDsp.normalize(mix, 0.85)
	SynthDsp.clip(mix)
	var stream := SynthDsp.to_audio_stream_wav(mix, _sample_rate, true)
	_chord_cache[sig] = stream
	return stream

func _note_stream(voice_name: String, midi: int) -> AudioStreamWAV:
	var key := "%s:%d" % [voice_name, midi]
	if _note_cache.has(key):
		return _note_cache[key]
	var presets := SynthPresets.music_voice_presets()
	if not presets.has(voice_name):
		return null
	var params: LocalAgentsSynthVoiceParamsResource = (presets[voice_name] as LocalAgentsSynthVoiceParamsResource).duplicate_params()
	var freq := Theory.midi_to_hz(midi)
	params.frequency = freq
	params.frequency_end = freq
	var stream := _voice.render_to_stream(params, _sample_rate, false)
	_note_cache[key] = stream
	return stream

# --- Players --------------------------------------------------------------------

func _build_players() -> void:
	for p in _all_players():
		if is_instance_valid(p):
			p.queue_free()
	_pad_players = _make_players(2)
	_bass_players = _make_players(2)
	_arp_players = _make_players(5)
	_melody_players = _make_players(3)
	_perc_players = _make_players(3)
	_pad_idx = 0

func _make_players(count: int) -> Array[AudioStreamPlayer]:
	var arr: Array[AudioStreamPlayer] = []
	for i in count:
		var p := AudioStreamPlayer.new()
		p.bus = _bus_or_master(_music_bus)
		add_child(p)
		arr.append(p)
	return arr

func _all_players() -> Array:
	return _pad_players + _bass_players + _arp_players + _melody_players + _perc_players

func _clamp_key(root: int) -> int:
	var r := root
	while r < KEY_MIN:
		r += 12
	while r > KEY_MAX:
		r -= 12
	return r

func _bus_or_master(bus: StringName) -> StringName:
	if AudioServer.get_bus_index(String(bus)) < 0:
		return &"Master"
	return bus
