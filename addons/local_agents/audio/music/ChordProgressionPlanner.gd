@tool
extends RefCounted
class_name LocalAgentsChordProgressionPlanner

## Generates chord progressions over any mode using functional-harmony weighting,
## seeded for reproducibility. Output is a list of chord events; playback lives in
## MusicDirector. Pure given (root, mode, rng, mood) → testable.
##
## Each event: {
##   "degree": int, "size": int, "octave": int,
##   "root_midi": int, "midis": Array[int], "quality": String
## }

const Theory := preload("res://addons/local_agents/audio/music/MusicTheory.gd")

# Functional transition weights for 7-degree modes (index = scale degree 0..6).
# Encodes the classic tonic → predominant → dominant → tonic pull.
const FUNCTIONAL_7 := {
	0: {3: 3, 4: 3, 5: 2, 1: 2, 2: 1},   # I → IV V vi ii iii
	1: {4: 4, 3: 2, 6: 1},               # ii → V IV vii
	2: {5: 3, 3: 2, 0: 1},               # iii → vi IV I
	3: {4: 4, 1: 2, 0: 2, 6: 1},         # IV → V ii I vii
	4: {0: 4, 5: 2, 3: 1},               # V → I vi IV
	5: {3: 3, 1: 2, 4: 2, 0: 1},         # vi → IV ii V I
	6: {0: 4, 2: 2},                     # vii → I iii
}

## Build a progression of `length` chords. `mood` keys used (optional):
##   tension (0..1) → chord size (triad vs 7th vs 9th) and darker choices
##   brightness (0..1) → register
func plan(root_midi: int, mode: String, length: int, rng: RandomNumberGenerator, mood: Dictionary = {}) -> Array:
	var n := Theory.degree_count(mode)
	var tension := clampf(float(mood.get("tension", 0.3)), 0.0, 1.0)
	var events: Array = []
	var degree := 0                       # always open on the tonic
	var bars := maxi(1, length)
	for bar in bars:
		var is_last := bar == bars - 1
		if is_last:
			degree = 0                    # cadential resolution to tonic
		var size := _chord_size(tension, rng)
		var octave := 0
		var midis := Theory.chord_midis(root_midi, mode, degree, size, octave)
		events.append({
			"degree": degree,
			"size": size,
			"octave": octave,
			"root_midi": Theory.degree_to_midi(root_midi, mode, degree, octave),
			"midis": midis,
			"quality": Theory.triad_quality(midis),
		})
		if not is_last:
			degree = _next_degree(degree, n, rng)
	return events

## Same as `plan`, but returns only the chord note-lists (Array of Array[int] midi).
func plan_midis(root_midi: int, mode: String, length: int, rng: RandomNumberGenerator, mood: Dictionary = {}) -> Array:
	var chords: Array = []
	for event in plan(root_midi, mode, length, rng, mood):
		chords.append(event.get("midis", []))
	return chords

func _chord_size(tension: float, rng: RandomNumberGenerator) -> int:
	# Calm → triads; tense → sevenths, occasional ninth.
	var r := rng.randf()
	if tension < 0.33:
		return 3 if r < 0.85 else 4
	elif tension < 0.66:
		return 3 if r < 0.4 else 4
	else:
		if r < 0.25:
			return 3
		elif r < 0.8:
			return 4
		return 5

func _next_degree(degree: int, n: int, rng: RandomNumberGenerator) -> int:
	var weights := _candidate_weights(degree, n)
	return _weighted_pick(weights, rng)

func _candidate_weights(degree: int, n: int) -> Dictionary:
	if n == 7 and FUNCTIONAL_7.has(degree):
		return FUNCTIONAL_7[degree]
	# Generic pull for non-heptatonic modes: favor tonic + fourth/fifth-ish motion.
	var w := {}
	w[0] = 3
	w[posmod(degree + 3, n)] = 3         # up a fourth in degree space
	w[posmod(degree + n - 3, n)] = 2     # down a fourth
	w[posmod(degree + 2, n)] = 2
	w[posmod(degree + 1, n)] = 1
	w.erase(degree)                       # avoid immediate repeat
	if w.is_empty():
		w[0] = 1
	return w

func _weighted_pick(weights: Dictionary, rng: RandomNumberGenerator) -> int:
	var total := 0.0
	for k in weights:
		total += float(weights[k])
	if total <= 0.0:
		return 0
	var roll := rng.randf() * total
	var acc := 0.0
	for k in weights:
		acc += float(weights[k])
		if roll <= acc:
			return int(k)
	return int(weights.keys()[weights.size() - 1])
