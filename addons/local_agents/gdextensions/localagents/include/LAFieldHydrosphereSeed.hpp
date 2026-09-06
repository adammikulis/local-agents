#ifndef LOCAL_AGENTS_LA_FIELD_HYDROSPHERE_SEED_HPP
#define LOCAL_AGENTS_LA_FIELD_HYDROSPHERE_SEED_HPP

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>

namespace godot {

// THE BODY'S OWN WATER: the free surface LAWaterFill left over this box, and the pore water under the
// table the regolith walk marks. Nothing here decides a level; the fill did, over the whole body.
class LAFieldHydrosphereSeed : public RefCounted {
	GDCLASS(LAFieldHydrosphereSeed, RefCounted);

public:
	static void seed(Object *p_field);
	// Regolith cells, and how many of them carry pore water: where the table stands in this box.
	static Dictionary wetness(Object *p_field);

protected:
	static void _bind_methods();
};

} // namespace godot

#endif // LOCAL_AGENTS_LA_FIELD_HYDROSPHERE_SEED_HPP
