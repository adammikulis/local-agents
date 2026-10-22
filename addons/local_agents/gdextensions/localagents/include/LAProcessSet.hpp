#ifndef LOCAL_AGENTS_LA_PROCESS_SET_HPP
#define LOCAL_AGENTS_LA_PROCESS_SET_HPP

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/binder_common.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/string.hpp>

namespace godot {

// Which processes a world contains. A rung is a smaller, physically complete world; a process outside
// the set is absent -- never allocated, dispatched, reduced or booked. Resolved once at seeding, so no
// pass reads a flag per step.
class LAProcessSet : public RefCounted {
	GDCLASS(LAProcessSet, RefCounted);

public:
	enum Rung {
		STATE = 0,
		GRAVITY = 1,
		HYDROSTATIC = 2,
		ACOUSTIC = 3,
		CONDUCTION = 4,
		ADVECT = 5,
		WATER = 6,
		RADIATION = 7,
		CHEMISTRY = 8,
	};

	static const int TOP = CHEMISTRY;
	static const int UNSET = -1;
	// A `rung` argument meaning "whatever this world declared".
	static const int ANY = -2;

	static Array rungs();

	static int resolve(int p_node);
	static PackedStringArray records_from_args();
	static int playable();

	static void declare(int p_rung);
	static void declare_records(const PackedStringArray &p_ids);
	// A world's declaration: the explicit set the command line names, else the rung `p_node` resolves to.
	static void declare_world(int p_node);
	static int active();
	static PackedStringArray custom();
	static String name_of(int p_rung);

	static Array records();
	static String record_id(const Dictionary &p_rec);
	static PackedStringArray records_upto(int p_rung);
	static bool has_record(const String &p_kind, const String &p_label, int p_rung);
	static Array live_rungs();

	// THE LIVE MASK, over the declared set. A process this world contains may be switched off and on at
	// any step; one the world lacks has no entry and no switch. `has_record` keeps answering "declared";
	// `is_active` answers "declared AND switched on", and is what every dispatcher reads.
	static String process_name(const String &p_kind, const String &p_label);
	static PackedStringArray process_names(int p_rung);
	static Dictionary process_entry(const String &p_name);
	static bool set_live(const String &p_name, bool p_on);
	static bool is_active(const String &p_kind, const String &p_label, int p_rung);
	// The switch alone. Absence of a process is not the same statement as its switch being off, so a
	// reader that must tell them apart asks this.
	static bool is_switched_on(const String &p_kind, const String &p_label);
	static Dictionary live_mask();
	// The field step a toggle from here on takes effect at, and whether one has since the last ask.
	static void note_step(int p_step);
	static bool take_toggled();

	static PackedStringArray pass_paths(const PackedStringArray &p_all_paths, int p_rung);
	static Array transport_rows(int p_rung);
	static Array reduce_rows(int p_rung);
	static int reduce_rung(const String &p_key, const PackedStringArray &p_book);
	static int channel_rung(const String &p_channel);
	static PackedStringArray row_books(const Dictionary &p_row);
	static PackedStringArray booked(int p_rung);
	static bool books(const String &p_channel);
	static Array reaction_records(int p_rung);

	// `@amounts` expands to the conserved stock pair of every LAReduceRecords.AMOUNTS entry.
	static String amounts_token();

	// Drops the reduce-row cache before the engine tears its memory down.
	static void release();

protected:
	static void _bind_methods();
};

} // namespace godot

VARIANT_ENUM_CAST(LAProcessSet::Rung);

#endif // LOCAL_AGENTS_LA_PROCESS_SET_HPP
