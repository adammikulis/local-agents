#ifndef LOCAL_AGENTS_LA_FIELD_STATE_CACHE_HPP
#define LOCAL_AGENTS_LA_FIELD_STATE_CACHE_HPP

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/vector3.hpp>

namespace godot {

// THE DISK CACHE FOR WHAT THE SEEDING WALKS PRODUCE, under user:// and outside the tracked tree. Two
// artifacts, each keyed by its own inputs: the solid mask the terrain SDF states, and the whole sealed
// field. Serial file work, so it is here rather than in the field's GDScript.
class LAFieldStateCache : public RefCounted {
	GDCLASS(LAFieldStateCache, RefCounted);

public:
	// The mask's address: the terrain generator's own inputs, the box, and the sources that decide the SDF.
	static String mask_key(const Dictionary &p_opts, int p_nx, int p_ny, int p_nz, double p_cell,
			const Vector3 &p_origin, const PackedStringArray &p_sources);

	// The sealed field's address: the tree key the harness measured, plus the box this field stands in.
	// An empty tree key returns an empty key, and an empty key is never a hit: a state nothing can
	// content-address is not one to reuse.
	static String state_key(const String &p_tree_key, int p_nx, int p_ny, int p_nz, double p_cell,
			const Vector3 &p_origin);
	static Dictionary load_state(const String &p_key, int p_cell_count);
	// A dictionary under a content key, unexamined: the caller knows what it stored.
	static Dictionary load_blob(const String &p_key);
	static void save_blob(const String &p_key, const Dictionary &p_data);
	static void save_state(const String &p_key, const Dictionary &p_data);

protected:
	static void _bind_methods();
};

} // namespace godot

#endif // LOCAL_AGENTS_LA_FIELD_STATE_CACHE_HPP
