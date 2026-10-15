#ifndef LOCAL_AGENTS_LA_ABLATE_HPP
#define LOCAL_AGENTS_LA_ABLATE_HPP

#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/string.hpp>

namespace godot {

// ONE REGISTRY for what a run can switch: the presentation modules a layer adopts, the physics processes
// the rung contains (LAProcessSet's live mask), and the stand-ins LAFakes declares, under one `set_on`,
// one `set_state`, one `names`, one `--ablate=` and one sweep. A process the rung lacks has no entry and
// asking for one is refused. A module and a process answer on/off; a stand-in answers off/fake/real.
// A module is its node's whole subtree. Moving an adopted root inside another module releases its
// former registration, restoring its state before the enclosing module takes ownership.
class LAAblate : public RefCounted {
	GDCLASS(LAAblate, RefCounted);

public:
	static String state_off();
	static String state_fake();
	static String state_real();

	static bool off(const String &p_name);
	static void adopt(const String &p_name, Node *p_node);
	// A stand-in, and the ladder rung whose arrival makes its `real` state the default (< 0: no rung).
	static void adopt_fake(const String &p_name, int p_rung);
	static void set_on(const String &p_name, bool p_on);
	static bool is_on(const String &p_name);
	// off: nothing supplies the quantity. fake: the registered stand-in. real: the field's own process.
	static void set_state(const String &p_name, const String &p_state);
	static String state_of(const String &p_name);
	static String default_state(const String &p_name);
	static int fake_rung(const String &p_name);
	static Dictionary fake_states();
	// "process" for one the rung contains, "module" for an adopted node, "fake" for a stand-in, "" else.
	static String kind_of(const String &p_name);
	// Processes in ladder order, then the adopted modules, then the stand-ins.
	static PackedStringArray names();
	// The modules that draw over the frame: every adopted module whose subtree holds a CanvasLayer.
	static PackedStringArray panels();
	// The switches this run's flags are due to throw by `step`, on the sim clock.
	static void apply_schedule(int p_step);
	// One field step's switches: note the clock, throw what is due, and say whether anything moved --
	// a thrown switch is a writer event, so the world it wakes takes a full step.
	static bool step_switches(int p_step);

	static String life_full();
	static String life_no_fauna();
	static String life_planet_only();
	static String life_mode();
	static bool fauna_off();
	static bool flora_off();
	static double evo_fast();

	static void release();

protected:
	static void _bind_methods();
};

} // namespace godot

#endif // LOCAL_AGENTS_LA_ABLATE_HPP
