@tool
extends RefCounted

## Tests the generative music stack: theory (modes incl. Phrygian dominant), Roman-
## numeral resolution, the progression library, the seeded planner, the song
## arranger's evolution (key/mode/meter changes), and MusicDirector's runtime API.

const Theory := preload("res://addons/local_agents/audio/music/MusicTheory.gd")
const Roman := preload("res://addons/local_agents/audio/music/RomanNumeral.gd")
const Library := preload("res://addons/local_agents/audio/music/ChordProgressionLibrary.gd")
const Planner := preload("res://addons/local_agents/audio/music/ChordProgressionPlanner.gd")
const Arranger := preload("res://addons/local_agents/audio/music/SongArranger.gd")
const MusicDirector := preload("res://addons/local_agents/audio/MusicDirector.gd")

func run_test(tree: SceneTree) -> bool:
	if not _test_theory():
		return false
	if not _test_roman():
		return false
	if not _test_library():
		return false
	if not _test_planner_determinism():
		return false
	if not _test_arranger_evolves():
		return false
	if not _test_music_director(tree):
		return false
	return true

func _test_theory() -> bool:
	if not Theory.has_mode("phrygian_dominant"):
		push_error("phrygian_dominant mode missing")
		return false
	if Theory.intervals("phrygian_dominant") != [0, 1, 4, 5, 7, 8, 10]:
		push_error("phrygian_dominant intervals wrong")
		return false
	# Triad on the ionian tonic in C = C major.
	if Theory.chord_midis(60, "ionian", 0, 3) != [60, 64, 67]:
		push_error("C ionian I triad wrong: %s" % str(Theory.chord_midis(60, "ionian", 0, 3)))
		return false
	# Degree wrap: degree 7 in a 7-note mode = root one octave up.
	if Theory.degree_to_midi(60, "ionian", 7) != 72:
		push_error("degree wrap failed")
		return false
	if Theory.midi_to_name(69) != "A4":
		push_error("midi_to_name(69) != A4")
		return false
	if Theory.name_to_midi("A4") != 69 or Theory.name_to_midi("C#3") != 49:
		push_error("name_to_midi failed")
		return false
	if not Theory.midi_in_mode(64, 60, "ionian") or Theory.midi_in_mode(61, 60, "ionian"):
		push_error("midi_in_mode failed")
		return false
	return true

func _test_roman() -> bool:
	if Roman.resolve("I", 60) != [60, 64, 67]:
		push_error("Roman I wrong")
		return false
	if Roman.resolve("vi", 60) != [69, 72, 76]:
		push_error("Roman vi wrong: %s" % str(Roman.resolve("vi", 60)))
		return false
	if Roman.resolve("bVII", 60) != [70, 74, 77]:
		push_error("Roman bVII wrong: %s" % str(Roman.resolve("bVII", 60)))
		return false
	if Roman.resolve("V7", 60) != [67, 71, 74, 77]:
		push_error("Roman V7 wrong: %s" % str(Roman.resolve("V7", 60)))
		return false
	if Roman.resolve("iiø", 60) != [62, 65, 68, 72]:
		push_error("Roman iiø (half-dim) wrong: %s" % str(Roman.resolve("iiø", 60)))
		return false
	var p := Roman.parse("Imaj7")
	if p.get("quality") != "maj7":
		push_error("Imaj7 quality wrong: %s" % str(p))
		return false
	return true

func _test_library() -> bool:
	if not Library.has_progression("I–V–vi–IV"):
		push_error("axis progression missing from library")
		return false
	# Every catalog entry must resolve to a non-empty chord list, and each entry
	# must carry a song example.
	for name in Library.names():
		var chords := Library.resolve(name, 60, 0)
		if chords.is_empty():
			push_error("progression '%s' resolved empty" % name)
			return false
		for c in chords:
			if (c as Array).is_empty():
				push_error("progression '%s' has an empty chord" % name)
				return false
		var entry := Library.get_entry(name)
		if String(entry.get("example", "")) == "":
			push_error("progression '%s' missing a song example" % name)
			return false
	if Library.describe_all().is_empty():
		push_error("describe_all empty")
		return false
	return true

func _test_planner_determinism() -> bool:
	var planner := Planner.new()
	var mood := {"tension": 0.4}
	var rng_a := RandomNumberGenerator.new()
	rng_a.seed = 777
	var rng_b := RandomNumberGenerator.new()
	rng_b.seed = 777
	var a := planner.plan_midis(45, "phrygian_dominant", 5, rng_a, mood)
	var b := planner.plan_midis(45, "phrygian_dominant", 5, rng_b, mood)
	if a.size() != 5:
		push_error("planner length wrong: %d" % a.size())
		return false
	if str(a) != str(b):
		push_error("planner not deterministic for a fixed seed")
		return false
	for chord in a:
		if (chord as Array).is_empty():
			push_error("planner produced an empty chord")
			return false
		# Chord root must belong to the mode.
		if not Theory.midi_in_mode(int(chord[0]), 45, "phrygian_dominant"):
			push_error("planner chord root out of mode: %d" % int(chord[0]))
			return false
	return true

func _test_arranger_evolves() -> bool:
	var arranger := Arranger.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	var saw_modulation := false
	var saw_mode_change := false
	var saw_bridge := false
	var saw_chorus := false
	for i in 40:
		var section := arranger.next_section(rng, true, true)
		if int(section.get("key_modulation", 0)) != 0:
			saw_modulation = true
		if String(section.get("mode", "")) != "":
			saw_mode_change = true
		var label := String(section.get("label", ""))
		if label == "bridge":
			saw_bridge = true
		if label == "chorus":
			saw_chorus = true
	if not (saw_modulation and saw_mode_change and saw_bridge and saw_chorus):
		push_error("arranger did not evolve: mod=%s mode=%s bridge=%s chorus=%s" % [saw_modulation, saw_mode_change, saw_bridge, saw_chorus])
		return false
	return true

func _test_music_director(tree: SceneTree) -> bool:
	var md := MusicDirector.new()
	tree.root.add_child(md)
	md.configure(null, 22050, 2024)
	if md.progression_midis().is_empty():
		push_error("music director produced no progression")
		md.queue_free()
		return false
	# Pick a mode mid-flight.
	md.set_mode("phrygian_dominant")
	if md.current_mode() != "phrygian_dominant" or md.progression_midis().is_empty():
		push_error("set_mode did not take effect")
		md.queue_free()
		return false
	# Switch to a named library progression.
	md.set_progression("ii–V–I")
	if md.progression_midis().size() != 3:
		push_error("library progression size wrong: %d" % md.progression_midis().size())
		md.queue_free()
		return false
	# Change meter and key mid-song.
	md.set_time_signature(7)
	if md.time_signature() != 7:
		push_error("time signature change failed")
		md.queue_free()
		return false
	md.set_key("C3")
	var key_root: int = md.current_key_root()
	var section_label: String = md.current_section_label()
	md.queue_free()
	if key_root != 48:
		push_error("set_key(C3) expected root 48, got %d" % key_root)
		return false
	if section_label == "":
		push_error("music director has no current section")
		return false
	return true
