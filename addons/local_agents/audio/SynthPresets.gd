@tool
extends RefCounted
class_name LocalAgentsSynthPresets

## A curated library of good-sounding starting points, so a user (or an LLM agent)
## can pick a named preset and tweak from there instead of dialing in raw DSP.
##
## Two families:
##   sfx_presets()          — one-shot event sounds (impacts, creatures, UI, …)
##   music_voice_presets()  — sustained pads/drones + melodic voices for MusicDirector
##
## Everything is tuned toward the project's naturalistic/ambient aesthetic
## (filtered pink noise for impacts, soft-filtered triangles/sines for pads).
## All presets are plain `LocalAgentsSynthVoiceParamsResource` — enumerate them,
## `duplicate_params()`, and adjust any field.

const Params := preload("res://addons/local_agents/audio/params/SynthVoiceParamsResource.gd")

# --- SFX one-shots ---------------------------------------------------------------

static func sfx_presets() -> Dictionary:
	var W := Params.Waveform
	var F := Params.FilterType
	var N := Params.NoiseType
	return {
		# Dull, low thud — projectile hitting soft terrain.
		"impact_soft": Params.make({
			"noise_mix": 1.0, "noise_type": N.PINK,
			"frequency": 140.0, "frequency_end": 90.0, "duration": 0.30,
			"attack": 0.002, "decay": 0.18, "sustain": 0.0, "release": 0.10,
			"filter_type": F.LOWPASS, "filter_cutoff": 900.0, "filter_q": 0.9,
			"amplitude": 0.85, "seed": 101,
		}),
		# Sharp crack — projectile hitting hard/dense voxels.
		"impact_hard": Params.make({
			"waveform": W.TRIANGLE, "noise_mix": 0.72, "noise_type": N.PINK,
			"frequency": 320.0, "frequency_end": 120.0, "duration": 0.22,
			"attack": 0.001, "decay": 0.12, "sustain": 0.0, "release": 0.07,
			"filter_type": F.LOWPASS, "filter_cutoff": 3200.0, "filter_q": 1.1,
			"amplitude": 0.92, "seed": 102,
		}),
		# Rubble/debris settling — grainy mid band.
		"crumble": Params.make({
			"noise_mix": 1.0, "noise_type": N.PINK,
			"frequency": 200.0, "frequency_end": 200.0, "duration": 0.45,
			"attack": 0.004, "decay": 0.30, "sustain": 0.05, "release": 0.14,
			"filter_type": F.BANDPASS, "filter_cutoff": 1600.0, "filter_q": 1.4,
			"amplitude": 0.7, "seed": 103,
		}),
		# Launcher fire — airy filtered-noise whoosh with a little body.
		"fire": Params.make({
			"waveform": W.SAW, "noise_mix": 0.8, "noise_type": N.WHITE,
			"frequency": 520.0, "frequency_end": 220.0, "duration": 0.26,
			"attack": 0.002, "decay": 0.16, "sustain": 0.0, "release": 0.08,
			"filter_type": F.HIGHPASS, "filter_cutoff": 700.0, "filter_q": 0.8,
			"amplitude": 0.8, "seed": 104,
		}),
		# Big low boom — meteor / large explosion.
		"meteor_impact": Params.make({
			"noise_mix": 0.9, "noise_type": N.PINK,
			"frequency": 90.0, "frequency_end": 45.0, "duration": 1.20,
			"attack": 0.002, "decay": 0.70, "sustain": 0.12, "release": 0.45,
			"filter_type": F.LOWPASS, "filter_cutoff": 480.0, "filter_q": 1.0,
			"amplitude": 1.0, "seed": 105,
		}),
		# Thunder — a sharp crack over a long low rolling rumble.
		"thunder": Params.make({
			"noise_mix": 0.95, "noise_type": N.PINK,
			"frequency": 160.0, "frequency_end": 55.0, "duration": 1.60,
			"attack": 0.001, "decay": 0.55, "sustain": 0.18, "release": 0.70,
			"filter_type": F.LOWPASS, "filter_cutoff": 900.0, "filter_q": 1.3,
			"amplitude": 1.0, "seed": 123,
		}),
		# Sizzle — hot rock/lava meeting water: sharp high hiss that fades fast (flash-steam).
		"sizzle": Params.make({
			"noise_mix": 1.0, "noise_type": N.WHITE,
			"frequency": 2000.0, "frequency_end": 1400.0, "duration": 0.55,
			"attack": 0.003, "decay": 0.34, "sustain": 0.10, "release": 0.16,
			"filter_type": F.HIGHPASS, "filter_cutoff": 2600.0, "filter_q": 0.7,
			"amplitude": 0.6, "seed": 121,
		}),
		# Rolling boil / steam vent — sustained airy hiss with a little body.
		"steam": Params.make({
			"noise_mix": 1.0, "noise_type": N.WHITE,
			"frequency": 900.0, "frequency_end": 700.0, "duration": 1.10,
			"attack": 0.02, "decay": 0.35, "sustain": 0.4, "release": 0.35,
			"filter_type": F.BANDPASS, "filter_cutoff": 1300.0, "filter_q": 1.2,
			"amplitude": 0.5, "seed": 122,
		}),
		# Predator eats prey — quick downward chirp + bite.
		"chomp": Params.make({
			"waveform": W.SQUARE, "duty": 0.35, "noise_mix": 0.4, "noise_type": N.PINK,
			"frequency": 420.0, "frequency_end": 160.0, "duration": 0.14,
			"attack": 0.001, "decay": 0.08, "sustain": 0.0, "release": 0.05,
			"filter_type": F.LOWPASS, "filter_cutoff": 2600.0, "filter_q": 0.9,
			"amplitude": 0.7, "seed": 106,
		}),
		# Creature death — soft descending tone.
		"death": Params.make({
			"waveform": W.SAW, "noise_mix": 0.12,
			"frequency": 300.0, "frequency_end": 110.0, "duration": 0.55,
			"attack": 0.004, "decay": 0.30, "sustain": 0.2, "release": 0.22,
			"filter_type": F.LOWPASS, "filter_cutoff": 1800.0, "filter_q": 0.8,
			"amplitude": 0.72, "seed": 107,
		}),
		# Spawn/pop-in — gentle rising blip.
		"spawn": Params.make({
			"waveform": W.TRIANGLE, "noise_mix": 0.0,
			"frequency": 330.0, "frequency_end": 620.0, "duration": 0.20,
			"attack": 0.006, "decay": 0.12, "sustain": 0.0, "release": 0.06,
			"filter_type": F.LOWPASS, "filter_cutoff": 6000.0, "filter_q": 0.7,
			"amplitude": 0.6, "seed": 108,
		}),
		# Forage/pickup — bright ascending two-tone-ish blip.
		"pickup": Params.make({
			"waveform": W.TRIANGLE,
			"frequency": 660.0, "frequency_end": 990.0, "duration": 0.16,
			"attack": 0.002, "decay": 0.10, "sustain": 0.0, "release": 0.05,
			"filter_type": F.NONE,
			"amplitude": 0.6, "seed": 109,
		}),
		# UI transport click.
		"ui_click": Params.make({
			"waveform": W.SINE,
			"frequency": 880.0, "frequency_end": 880.0, "duration": 0.06,
			"attack": 0.001, "decay": 0.04, "sustain": 0.0, "release": 0.02,
			"filter_type": F.NONE,
			"amplitude": 0.45, "seed": 110,
		}),
		# UI rewind — descending sweep.
		"ui_rewind": Params.make({
			"waveform": W.SINE,
			"frequency": 900.0, "frequency_end": 300.0, "duration": 0.28,
			"attack": 0.002, "decay": 0.18, "sustain": 0.0, "release": 0.08,
			"filter_type": F.NONE,
			"amplitude": 0.5, "seed": 111,
		}),
	}

# --- Music voices ---------------------------------------------------------------
# Pads are rendered looped (long, sustained); melodic voices are one-shots retuned
# per note by MusicDirector.

static func music_voice_presets() -> Dictionary:
	var W := Params.Waveform
	var F := Params.FilterType
	var N := Params.NoiseType
	return {
		# Warm low drone — the ambient bed. Long attack/release, high sustain.
		"pad_warm": Params.make({
			"waveform": W.TRIANGLE, "noise_mix": 0.0,
			"frequency": 110.0, "frequency_end": 110.0, "duration": 4.0,
			"attack": 1.2, "decay": 0.6, "sustain": 0.85, "release": 1.4,
			"filter_type": F.LOWPASS, "filter_cutoff": 900.0, "filter_q": 0.7,
			"amplitude": 0.5, "seed": 201,
		}),
		# Airy upper pad — adds shimmer above the warm drone.
		"pad_airy": Params.make({
			"waveform": W.SINE, "noise_mix": 0.05,
			"frequency": 330.0, "frequency_end": 330.0, "duration": 4.0,
			"attack": 1.6, "decay": 0.8, "sustain": 0.7, "release": 1.8,
			"filter_type": F.LOWPASS, "filter_cutoff": 2400.0, "filter_q": 0.6,
			"amplitude": 0.35, "seed": 202,
		}),
		# Soft bell — sparse melodic motif, fast attack, long ringing decay.
		"bell": Params.make({
			"waveform": W.SINE,
			"frequency": 440.0, "frequency_end": 440.0, "duration": 1.6,
			"attack": 0.004, "decay": 1.1, "sustain": 0.0, "release": 0.4,
			"filter_type": F.LOWPASS, "filter_cutoff": 5000.0, "filter_q": 0.7,
			"amplitude": 0.45, "seed": 203,
		}),
		# Wooden mallet — warmer, shorter melodic voice.
		"marimba": Params.make({
			"waveform": W.TRIANGLE,
			"frequency": 440.0, "frequency_end": 440.0, "duration": 0.7,
			"attack": 0.003, "decay": 0.5, "sustain": 0.0, "release": 0.18,
			"filter_type": F.LOWPASS, "filter_cutoff": 3000.0, "filter_q": 0.8,
			"amplitude": 0.5, "seed": 204,
		}),
		# Sub bass — round low root notes on downbeats.
		"bass": Params.make({
			"waveform": W.SINE, "noise_mix": 0.0,
			"frequency": 82.0, "frequency_end": 82.0, "duration": 0.9,
			"attack": 0.006, "decay": 0.4, "sustain": 0.5, "release": 0.2,
			"filter_type": F.LOWPASS, "filter_cutoff": 600.0, "filter_q": 0.7,
			"amplitude": 0.6, "seed": 205,
		}),
		# Pluck — short bright voice for arpeggios.
		"pluck": Params.make({
			"waveform": W.SAW, "noise_mix": 0.0,
			"frequency": 440.0, "frequency_end": 440.0, "duration": 0.35,
			"attack": 0.002, "decay": 0.22, "sustain": 0.0, "release": 0.08,
			"filter_type": F.LOWPASS, "filter_cutoff": 3200.0, "filter_q": 1.2,
			"amplitude": 0.42, "seed": 206,
		}),
		# Soft percussion tick — filtered noise, used for gentle rhythm.
		"perc_tick": Params.make({
			"noise_mix": 1.0, "noise_type": N.WHITE,
			"frequency": 200.0, "frequency_end": 200.0, "duration": 0.09,
			"attack": 0.001, "decay": 0.06, "sustain": 0.0, "release": 0.02,
			"filter_type": F.BANDPASS, "filter_cutoff": 4000.0, "filter_q": 1.6,
			"amplitude": 0.3, "seed": 207,
		}),
	}

# --- Lookup helpers -------------------------------------------------------------

## Every preset (SFX + music) merged, for enumeration by editors/agents.
static func all_presets() -> Dictionary:
	var merged := sfx_presets()
	merged.merge(music_voice_presets())
	return merged

static func preset_names() -> Array:
	return all_presets().keys()

## Fetch a fresh (deep-duplicated) copy of a named preset, or null if unknown.
static func get_preset(preset_name: String) -> LocalAgentsSynthVoiceParamsResource:
	var all := all_presets()
	if not all.has(preset_name):
		return null
	return (all[preset_name] as LocalAgentsSynthVoiceParamsResource).duplicate_params()
