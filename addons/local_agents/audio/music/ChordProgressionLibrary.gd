@tool
extends RefCounted
class_name LocalAgentsChordProgressionLibrary

## A catalog of well-known chord progressions as Roman-numeral token lists, each
## annotated with a song that famously uses it, the tonality it lives in, and a
## short "feel" tag. A user or LLM agent can enumerate these, pick one by name, and
## MusicDirector will resolve it into the chosen key via RomanNumeral.
##
## Roman numerals are anchored to the tonic's major scale; minor-key progressions
## use flats (i, bIII, iv, v/V, bVI, bVII) so both tonalities share one notation.

const Roman := preload("res://addons/local_agents/audio/music/RomanNumeral.gd")

# name -> { chords:[tokens], key:"major"|"minor", example:String, feel:String }
const CATALOG := {
	# ---- Pop / rock staples ----
	"I–V–vi–IV": {
		"chords": ["I", "V", "vi", "IV"], "key": "major",
		"example": "Journey – \"Don't Stop Believin'\"", "feel": "anthemic pop",
	},
	"I–vi–IV–V": {
		"chords": ["I", "vi", "IV", "V"], "key": "major",
		"example": "Ben E. King – \"Stand By Me\" (50s doo-wop)", "feel": "nostalgic",
	},
	"vi–IV–I–V": {
		"chords": ["vi", "IV", "I", "V"], "key": "major",
		"example": "Linkin Park – \"Numb\"", "feel": "bittersweet",
	},
	"I–IV–V": {
		"chords": ["I", "IV", "V"], "key": "major",
		"example": "Ritchie Valens – \"La Bamba\"", "feel": "three-chord rock",
	},
	"I–IV–V–IV": {
		"chords": ["I", "IV", "V", "IV"], "key": "major",
		"example": "The Troggs – \"Wild Thing\"", "feel": "garage rock",
	},
	"I–bVII–IV": {
		"chords": ["I", "bVII", "IV"], "key": "major",
		"example": "Lynyrd Skynyrd – \"Sweet Home Alabama\"", "feel": "southern rock (mixolydian)",
	},
	"I–V–IV": {
		"chords": ["I", "V", "IV"], "key": "major",
		"example": "The Kingsmen – \"Louie Louie\"", "feel": "loose rock",
	},
	"IV–I–V–vi": {
		"chords": ["IV", "I", "V", "vi"], "key": "major",
		"example": "The Beatles – \"Something\" (rotation of the axis)", "feel": "warm",
	},
	"I–iii–IV–V": {
		"chords": ["I", "iii", "IV", "V"], "key": "major",
		"example": "The Ronettes – \"Be My Baby\"", "feel": "wall-of-sound",
	},

	# ---- Doo-wop / jazz turnarounds ----
	"I–vi–ii–V": {
		"chords": ["Imaj7", "vi7", "ii7", "V7"], "key": "major",
		"example": "Rodgers & Hart – \"Blue Moon\"", "feel": "jazzy turnaround",
	},
	"ii–V–I": {
		"chords": ["ii7", "V7", "Imaj7"], "key": "major",
		"example": "Miles Davis – \"Tune Up\"", "feel": "jazz cadence",
	},
	"iii–vi–ii–V": {
		"chords": ["iii7", "vi7", "ii7", "V7"], "key": "major",
		"example": "\"Rhythm changes\" bridge (Gershwin – \"I Got Rhythm\")", "feel": "bebop",
	},
	" minor ii–V–i": {
		"chords": ["iiø", "V7", "i"], "key": "minor",
		"example": "Kosma – \"Autumn Leaves\"", "feel": "minor jazz cadence",
	},

	# ---- Classical / baroque ----
	"Pachelbel I–V–vi–iii–IV–I–IV–V": {
		"chords": ["I", "V", "vi", "iii", "IV", "I", "IV", "V"], "key": "major",
		"example": "Pachelbel – \"Canon in D\"", "feel": "baroque, cyclic",
	},
	"IV–I plagal (Amen)": {
		"chords": ["IV", "I"], "key": "major",
		"example": "Hymn \"Amen\" cadence", "feel": "resolving, sacred",
	},
	"Andalusian i–bVII–bVI–V": {
		"chords": ["i", "bVII", "bVI", "V"], "key": "minor",
		"example": "Ray Charles – \"Hit the Road Jack\"", "feel": "Spanish/Phrygian descent",
	},

	# ---- Minor / epic ----
	"i–bVI–bIII–bVII": {
		"chords": ["i", "bVI", "bIII", "bVII"], "key": "minor",
		"example": "Iggy Pop – \"The Passenger\"", "feel": "driving minor",
	},
	"i–bVII–bVI–bVII": {
		"chords": ["i", "bVII", "bVI", "bVII"], "key": "minor",
		"example": "Bob Dylan – \"All Along the Watchtower\"", "feel": "modal rock",
	},
	"i–iv–v": {
		"chords": ["i", "iv", "v"], "key": "minor",
		"example": "Minor folk / \"Sinnerman\"", "feel": "somber",
	},
	"i–bVI–bVII–i": {
		"chords": ["i", "bVI", "bVII", "i"], "key": "minor",
		"example": "Europe – \"The Final Countdown\" feel", "feel": "epic/celtic",
	},
	"i–V–i (harmonic minor)": {
		"chords": ["i", "V7", "i"], "key": "minor",
		"example": "Classical minor cadence (Bach)", "feel": "dramatic resolution",
	},
	"i–iv–bVII–bIII–bVI–iiø–V": {
		"chords": ["i", "iv", "bVII", "bIII", "bVI", "iiø", "V7"], "key": "minor",
		"example": "Gloria Gaynor – \"I Will Survive\" (minor circle of fifths)", "feel": "cascading",
	},

	# ---- Modal / cinematic ----
	"Lydian I–II": {
		"chords": ["Imaj7", "II"], "key": "major",
		"example": "Fleetwood Mac – \"Dreams\"", "feel": "floating (lydian)",
	},
	"Phrygian i–bII": {
		"chords": ["i", "bII"], "key": "minor",
		"example": "Flamenco / metal Phrygian vamp", "feel": "dark, exotic",
	},
	"Mixolydian I–bVII–IV–I": {
		"chords": ["I", "bVII", "IV", "I"], "key": "major",
		"example": "The Beatles – \"Norwegian Wood\" feel", "feel": "folk-modal",
	},

	# ---- J-pop / anime ----
	"Royal Road IV–V–iii–vi": {
		"chords": ["IVmaj7", "V7", "iii7", "vi"], "key": "major",
		"example": "Common J-pop / anime \"Royal Road\" (e.g. YOASOBI)", "feel": "emotional J-pop",
	},
	"Komuro vi–IV–V–I": {
		"chords": ["vi", "IV", "V", "I"], "key": "major",
		"example": "Tetsuya Komuro-style J-pop", "feel": "uplift resolve",
	},

	# ---- Blues ----
	"12-bar blues": {
		"chords": ["I7", "I7", "I7", "I7", "IV7", "IV7", "I7", "I7", "V7", "IV7", "I7", "V7"], "key": "major",
		"example": "Chuck Berry – \"Johnny B. Goode\"", "feel": "shuffle blues",
	},
	"minor blues": {
		"chords": ["i7", "iv7", "i7", "i7", "iv7", "iv7", "i7", "i7", "V7", "iv7", "i7", "V7"], "key": "minor",
		"example": "B.B. King – \"The Thrill Is Gone\"", "feel": "slow minor blues",
	},

	# ---- Advanced ----
	"Coltrane cycle (major thirds)": {
		"chords": ["Imaj7", "bIII7", "bVImaj7", "VII7", "IIImaj7", "V7"], "key": "major",
		"example": "John Coltrane – \"Giant Steps\"", "feel": "advanced jazz, key-shifting",
	},
	"I–V/V–V (secondary dominant)": {
		"chords": ["I", "II7", "V7"], "key": "major",
		"example": "\"Five Foot Two, Eyes of Blue\"", "feel": "ragtime brightness",
	},

	# ---- Ambient loops (few chords, slow) ----
	"Ambient Imaj7–vi7": {
		"chords": ["Imaj7", "vi7"], "key": "major",
		"example": "Brian Eno-style ambient", "feel": "calm, drifting",
	},
	"Ambient i–bVI": {
		"chords": ["i", "bVI"], "key": "minor",
		"example": "Cinematic underscore", "feel": "spacious melancholy",
	},
}

static func names() -> Array:
	return CATALOG.keys()

static func has_progression(name: String) -> bool:
	return CATALOG.has(name)

static func get_entry(name: String) -> Dictionary:
	return CATALOG.get(name, {})

static func tokens(name: String) -> Array:
	var e: Dictionary = CATALOG.get(name, {})
	return e.get("chords", [])

## Resolve a named progression to absolute MIDI chords in a key.
static func resolve(name: String, key_root_midi: int, octave: int = 0) -> Array:
	return Roman.resolve_progression(tokens(name), key_root_midi, octave)

## Compact, agent-friendly listing: name → "roman | example | feel".
static func describe_all() -> Dictionary:
	var out := {}
	for name in CATALOG:
		var e: Dictionary = CATALOG[name]
		var roman: String = " ".join(PackedStringArray(e.get("chords", [])))
		out[name] = "%s | %s | %s" % [roman, e.get("example", ""), e.get("feel", "")]
	return out
