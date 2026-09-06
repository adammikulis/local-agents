#ifndef LOCAL_AGENTS_LA_ABLATE_HPP
#define LOCAL_AGENTS_LA_ABLATE_HPP

#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/string.hpp>

namespace godot {

// ONE REGISTRY for what a run can switch off: the presentation modules a layer adopts and the physics
// processes the rung contains (LAProcessSet's live mask), under one `off`, one `set_on`, one `names`,
// one `--ablate=` and one sweep. A process the rung lacks has no entry and asking for one is refused.
class LAAblate : public RefCounted {
	GDCLASS(LAAblate, RefCounted);

public:
	static bool off(const String &p_name);
	static void adopt(const String &p_name, Node *p_node);
	static void set_on(const String &p_name, bool p_on);
	static bool is_on(const String &p_name);
	// "process" for one the rung contains, "module" for an adopted node, "" for a name neither holds.
	static String kind_of(const String &p_name);
	// Processes in ladder order, then the adopted modules.
	static PackedStringArray names();
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
