@tool
extends RefCounted
class_name LocalAgentsMusicTheory

## Pure, stateless music-theory library: scales/modes, diatonic chord construction,
## and note naming. No engine state, no RNG — trivially unit-testable and shared by
## the progression planner and the music director.
##
## A "mode" is an ordered array of semitone offsets from the root within one octave.
## Chords are built by stacking scale thirds (mode-aware), so e.g. a triad on a
## Phrygian-dominant tonic comes out correctly without hardcoding qualities.

# --- Scale / mode catalog (semitones from root) ---------------------------------

const MODES := {
	# --- Diatonic (major-scale) modes ---
	"ionian": [0, 2, 4, 5, 7, 9, 11],           # major
	"dorian": [0, 2, 3, 5, 7, 9, 10],
	"phrygian": [0, 1, 3, 5, 7, 8, 10],
	"lydian": [0, 2, 4, 6, 7, 9, 11],
	"mixolydian": [0, 2, 4, 5, 7, 9, 10],
	"aeolian": [0, 2, 3, 5, 7, 8, 10],           # natural minor
	"locrian": [0, 1, 3, 5, 6, 8, 10],

	# --- Harmonic-minor modes (incl. the requested Phrygian dominant) ---
	"harmonic_minor": [0, 2, 3, 5, 7, 8, 11],
	"locrian_nat6": [0, 1, 3, 5, 6, 9, 10],
	"ionian_aug": [0, 2, 4, 5, 8, 9, 11],
	"ukrainian_dorian": [0, 2, 3, 6, 7, 9, 10],  # dorian #4
	"phrygian_dominant": [0, 1, 4, 5, 7, 8, 10], # 5th mode of harmonic minor
	"lydian_sharp2": [0, 3, 4, 6, 7, 9, 11],
	"altered_bb7": [0, 1, 3, 4, 6, 8, 9],        # ultralocrian

	# --- Melodic-minor modes ---
	"melodic_minor": [0, 2, 3, 5, 7, 9, 11],
	"dorian_b2": [0, 1, 3, 5, 7, 9, 10],
	"lydian_augmented": [0, 2, 4, 6, 8, 9, 11],
	"lydian_dominant": [0, 2, 4, 6, 7, 9, 10],   # acoustic / overtone
	"mixolydian_b6": [0, 2, 4, 5, 7, 8, 10],
	"locrian_nat2": [0, 2, 3, 5, 6, 8, 10],
	"altered": [0, 1, 3, 4, 6, 8, 10],           # super locrian

	# --- Symmetric ---
	"whole_tone": [0, 2, 4, 6, 8, 10],
	"octatonic_hw": [0, 1, 3, 4, 6, 7, 9, 10],
	"octatonic_wh": [0, 2, 3, 5, 6, 8, 9, 11],
	"augmented": [0, 3, 4, 7, 8, 11],
	"chromatic": [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11],

	# --- Pentatonic / hexatonic / blues ---
	"major_pentatonic": [0, 2, 4, 7, 9],
	"minor_pentatonic": [0, 3, 5, 7, 10],
	"blues": [0, 3, 5, 6, 7, 10],
	"egyptian": [0, 2, 5, 7, 10],
	"hirajoshi": [0, 2, 3, 7, 8],
	"in_sen": [0, 1, 5, 7, 10],
	"iwato": [0, 1, 5, 6, 10],

	# --- Exotic / "world" heptatonics ---
	"hungarian_minor": [0, 2, 3, 6, 7, 8, 11],
	"double_harmonic": [0, 1, 4, 5, 7, 8, 11],   # byzantine
	"neapolitan_minor": [0, 1, 3, 5, 7, 8, 11],
	"neapolitan_major": [0, 1, 3, 5, 7, 9, 11],
	"persian": [0, 1, 4, 5, 6, 8, 11],
	"enigmatic": [0, 1, 4, 6, 8, 10, 11],
}

const NOTE_NAMES := ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

# --- Queries --------------------------------------------------------------------

static func mode_names() -> Array:
	return MODES.keys()

static func has_mode(mode: String) -> bool:
	return MODES.has(mode)

## Semitone intervals for `mode` (falls back to aeolian if unknown).
static func intervals(mode: String) -> Array:
	return MODES.get(mode, MODES["aeolian"])

static func degree_count(mode: String) -> int:
	return intervals(mode).size()

## Absolute MIDI for a scale degree, wrapping octaves for degrees beyond the mode
## size (degree 7 in a 7-note mode = root one octave up).
static func degree_to_midi(root_midi: int, mode: String, degree: int, octave: int = 0) -> int:
	var iv: Array = intervals(mode)
	var n := iv.size()
	var wrapped := posmod(degree, n)
	var extra_oct := int(floor(float(degree) / float(n)))
	return root_midi + int(iv[wrapped]) + 12 * (octave + extra_oct)

## Is `midi` a member of the mode rooted at `root_midi` (pitch-class test)?
static func midi_in_mode(midi: int, root_midi: int, mode: String) -> bool:
	return intervals(mode).has(posmod(midi - root_midi, 12))

## Snap an arbitrary midi to the nearest in-mode pitch (useful for voice-leading).
static func snap_to_mode(midi: int, root_midi: int, mode: String) -> int:
	if midi_in_mode(midi, root_midi, mode):
		return midi
	for d in range(1, 7):
		if midi_in_mode(midi + d, root_midi, mode):
			return midi + d
		if midi_in_mode(midi - d, root_midi, mode):
			return midi - d
	return midi

# --- Chords ---------------------------------------------------------------------

## Build a chord by stacking scale-thirds from `degree`. `size` = number of notes
## (3 = triad, 4 = seventh, 5 = ninth). Returns absolute MIDI notes, ascending.
static func chord_midis(root_midi: int, mode: String, degree: int, size: int = 3, octave: int = 0) -> Array:
	var notes: Array = []
	var count := clampi(size, 1, 6)
	for i in count:
		notes.append(degree_to_midi(root_midi, mode, degree + i * 2, octave))
	return notes

## Detect a triad quality label from its interval content (best-effort, for debug/UI).
static func triad_quality(chord: Array) -> String:
	if chord.size() < 3:
		return "?"
	var third := int(chord[1]) - int(chord[0])
	var fifth := int(chord[2]) - int(chord[0])
	if third == 4 and fifth == 7:
		return "maj"
	if third == 3 and fifth == 7:
		return "min"
	if third == 3 and fifth == 6:
		return "dim"
	if third == 4 and fifth == 8:
		return "aug"
	if third == 2:
		return "sus2"
	if third == 5:
		return "sus4"
	return "alt"

# --- Naming / conversion --------------------------------------------------------

static func midi_to_hz(midi: int) -> float:
	return 440.0 * pow(2.0, (float(midi) - 69.0) / 12.0)

static func midi_to_name(midi: int) -> String:
	var pc := posmod(midi, 12)
	var octave := int(floor(float(midi) / 12.0)) - 1
	return "%s%d" % [NOTE_NAMES[pc], octave]

## Parse a note name like "A2", "C#4", "Eb3" to MIDI (C4 = 60). Returns -1 on error.
static func name_to_midi(note: String) -> int:
	var s := note.strip_edges()
	if s.is_empty():
		return -1
	var letter := s.substr(0, 1).to_upper()
	var base := {"C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11}
	if not base.has(letter):
		return -1
	var pc := int(base[letter])
	var idx := 1
	while idx < s.length() and (s[idx] == "#" or s[idx] == "b"):
		pc += 1 if s[idx] == "#" else -1
		idx += 1
	var oct_str := s.substr(idx)
	if oct_str.is_empty() or not (oct_str.is_valid_int()):
		return -1
	var octave := oct_str.to_int()
	return (octave + 1) * 12 + pc
