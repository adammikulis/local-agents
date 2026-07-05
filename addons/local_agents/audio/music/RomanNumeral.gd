@tool
extends RefCounted
class_name LocalAgentsRomanNumeral

## Parses Roman-numeral chord tokens (I, ii, V7, vii°, bVII, IVmaj7, iiø, V+, …) and
## resolves them to absolute MIDI chords in a chosen key. Anchored to the major-scale
## of the tonic plus accidentals, so both major- and minor-key progressions are
## expressible (minor = i, bIII, iv, v/V, bVI, bVII). Pure/stateless → testable.

const Theory := preload("res://addons/local_agents/audio/music/MusicTheory.gd")

# Semitone of each Roman degree relative to the tonic (major-scale reference).
const MAJOR_REF := [0, 2, 4, 5, 7, 9, 11]   # I II III IV V VI VII

const NUMERALS := {
	"iii": 3, "vii": 7, "ii": 2, "iv": 4, "vi": 6, "i": 1, "v": 5,
}

## Parse one token → {degree:1..7, accidental:int, quality:String, intervals:Array}.
## Returns {} on failure.
static func parse(token: String) -> Dictionary:
	var s := token.strip_edges()
	if s.is_empty():
		return {}
	var i := 0
	var accidental := 0
	while i < s.length():
		var c := s[i]
		if c == "b" or c == "♭":
			accidental -= 1
			i += 1
		elif c == "#" or c == "♯":
			accidental += 1
			i += 1
		else:
			break
	# Read the roman letters (only i/I/v/V participate).
	var j := i
	while j < s.length() and (s[j] in "ivIV"):
		j += 1
	var roman := s.substr(i, j - i)
	if roman.is_empty():
		return {}
	var lower := roman.to_lower()
	if not NUMERALS.has(lower):
		return {}
	var degree := int(NUMERALS[lower])
	var uppercase := roman == roman.to_upper()
	var rest := s.substr(j)
	var intervals := _quality_intervals(uppercase, rest)
	return {
		"degree": degree,
		"accidental": accidental,
		"quality": _quality_label(uppercase, rest),
		"intervals": intervals,
	}

static func _quality_intervals(uppercase: bool, suffix: String) -> Array:
	var rl := suffix.to_lower()
	var has7 := rl.contains("7")
	# Diminished family.
	if suffix.contains("°") or suffix.contains("o") or rl.contains("dim"):
		return [0, 3, 6, 9] if has7 else [0, 3, 6]
	# Half-diminished.
	if suffix.contains("ø") or rl.contains("m7b5"):
		return [0, 3, 6, 10]
	# Augmented.
	if suffix.contains("+") or rl.contains("aug"):
		return [0, 4, 8, 10] if has7 else [0, 4, 8]
	# Major seventh.
	if rl.contains("maj7") or suffix.contains("M7"):
		return [0, 4, 7, 11] if uppercase else [0, 3, 7, 11]
	# Suspended.
	if rl.contains("sus2"):
		return [0, 2, 7]
	if rl.contains("sus4"):
		return [0, 5, 7]
	# Base triad by case.
	var base: Array = [0, 4, 7] if uppercase else [0, 3, 7]
	if has7:
		base = ([0, 4, 7, 10] if uppercase else [0, 3, 7, 10])   # dom7 / min7
	if rl.contains("6") and not has7:
		base = base.duplicate()
		base.append(9)
	if rl.contains("9"):
		base = base.duplicate()
		if not has7:
			base.append(10 if uppercase else 10)
		base.append(14)
	return base

static func _quality_label(uppercase: bool, suffix: String) -> String:
	var rl := suffix.to_lower()
	if suffix.contains("°") or rl.contains("dim"):
		return "dim7" if rl.contains("7") else "dim"
	if suffix.contains("ø") or rl.contains("m7b5"):
		return "m7b5"
	if suffix.contains("+") or rl.contains("aug"):
		return "aug"
	if rl.contains("maj7") or suffix.contains("M7"):
		return "maj7"
	if rl.contains("sus2"):
		return "sus2"
	if rl.contains("sus4"):
		return "sus4"
	if rl.contains("7"):
		return "dom7" if uppercase else "min7"
	return "maj" if uppercase else "min"

## Resolve a token to absolute MIDI notes in a key. `key_root_midi` is the tonic.
static func resolve(token: String, key_root_midi: int, octave: int = 0) -> Array:
	var p := parse(token)
	if p.is_empty():
		return []
	var root_semi := int(MAJOR_REF[int(p.degree) - 1]) + int(p.accidental)
	var root := key_root_midi + root_semi + 12 * octave
	var midis: Array = []
	for iv in p.intervals:
		midis.append(root + int(iv))
	return midis

## Resolve a whole progression (array of tokens) → array of chords (each an Array of midi).
static func resolve_progression(tokens: Array, key_root_midi: int, octave: int = 0) -> Array:
	var chords: Array = []
	for t in tokens:
		var c := resolve(String(t), key_root_midi, octave)
		if not c.is_empty():
			chords.append(c)
	return chords
