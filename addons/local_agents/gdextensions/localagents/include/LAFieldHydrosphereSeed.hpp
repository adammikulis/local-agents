#ifndef LOCAL_AGENTS_LA_FIELD_HYDROSPHERE_SEED_HPP
#define LOCAL_AGENTS_LA_FIELD_HYDROSPHERE_SEED_HPP

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>

namespace godot {

// THE BODY'S OWN WATER, laid into the basins the terrain gives it and the pore space the regolith walk
// marks. A priority-flood depression fill (Barnes et al. 2014) finds, in true 3D, the level any escape
// route out of a basin has to climb over; the ocean is the basin whose escape is the sea surface. At this
// cell size the body's water is a film on a basin floor, which the free-surface reconstruction carries.
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
