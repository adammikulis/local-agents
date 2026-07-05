@tool
extends RefCounted
class_name LocalAgentsSongArranger

## Drives long-form song structure so music evolves instead of looping four chords
## forever. Walks a section form (intro → verse → chorus → … → outro) and, at each
## section boundary, emits a descriptor that MusicDirector applies: section length,
## intensity, an optional key modulation, an optional mode change, an optional time
## signature change, and a tempo scale. Each full pass through the form applies a
## fresh modulation so repeats never sound identical. Seeded/pure → testable.

# Ordered section labels for one song cycle.
const FORM := ["intro", "verse", "chorus", "verse", "chorus", "bridge", "chorus", "outro"]

# Per-label intensity + behavior profile.
const PROFILE := {
	"intro":  {"bars": 4, "energy": 0.30, "density": 0.30, "register": 0, "contrast": false},
	"verse":  {"bars": 8, "energy": 0.50, "density": 0.50, "register": 0, "contrast": false},
	"chorus": {"bars": 8, "energy": 0.88, "density": 0.82, "register": 1, "contrast": false},
	"bridge": {"bars": 8, "energy": 0.62, "density": 0.60, "register": 0, "contrast": true},
	"outro":  {"bars": 4, "energy": 0.28, "density": 0.30, "register": 0, "contrast": false},
}

# Common modulations (semitones): up a fifth, up a whole step, down a third, up a
# half step ("truck-driver" gear change), relative shifts.
const MODULATIONS := [7, 2, -3, 1, 5, -5, 3]

# Time signatures worth visiting (beats per bar). Weighted toward 4.
const METERS := [4, 4, 4, 3, 6, 5, 7]

# Contrasting modes used on bridges / mode changes.
const MODE_PALETTE := [
	"ionian", "dorian", "aeolian", "lydian", "mixolydian",
	"phrygian_dominant", "harmonic_minor", "melodic_minor", "lydian_dominant",
]

var _idx: int = 0
var _passes: int = 0

func reset() -> void:
	_idx = 0
	_passes = 0

func current_label() -> String:
	return FORM[_idx % FORM.size()]

## Produce the next section descriptor. Flags gate optional changes so a caller can,
## e.g., forbid meter changes.
func next_section(rng: RandomNumberGenerator, allow_mode_change: bool = true, allow_meter_change: bool = true) -> Dictionary:
	var label: String = FORM[_idx % FORM.size()]
	var is_form_start := (_idx % FORM.size()) == 0
	if is_form_start and _idx > 0:
		_passes += 1
	_idx += 1
	var profile: Dictionary = PROFILE.get(label, PROFILE["verse"])

	var section := {
		"label": label,
		"bars": int(profile["bars"]),
		"energy": float(profile["energy"]),
		"density": float(profile["density"]),
		"register": int(profile["register"]),
		"contrast": bool(profile.get("contrast", false)),
		"key_modulation": 0,
		"mode": "",
		"beats_per_bar": 0,           # 0 = keep current
		"tempo_scale": lerpf(0.9, 1.08, float(profile["energy"])),
		"pass": _passes,
	}

	# Modulate at the top of each new pass, and on bridges.
	var new_pass := is_form_start and _idx > 1
	if new_pass or label == "bridge":
		section["key_modulation"] = MODULATIONS[rng.randi_range(0, MODULATIONS.size() - 1)]

	# Mode change on bridges (contrast) and sometimes on a new pass.
	if allow_mode_change and (label == "bridge" or (new_pass and rng.randf() < 0.5)):
		section["mode"] = MODE_PALETTE[rng.randi_range(0, MODE_PALETTE.size() - 1)]

	# Occasional time-signature change (mostly on bridges / new passes).
	if allow_meter_change and (label == "bridge" or new_pass) and rng.randf() < 0.4:
		section["beats_per_bar"] = METERS[rng.randi_range(0, METERS.size() - 1)]

	return section
