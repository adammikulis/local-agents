#ifndef LOCAL_AGENTS_LA_FIELD_HYDROSPHERE_SEED_HPP
#define LOCAL_AGENTS_LA_FIELD_HYDROSPHERE_SEED_HPP

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>

namespace godot {

// THE BODY'S OWN WATER, laid into the sea the terrain's shape holds and the pores the regolith walk opens
// below the water table, each at the density its own state gives it.
class LAFieldHydrosphereSeed : public RefCounted {
	GDCLASS(LAFieldHydrosphereSeed, RefCounted);

public:
	// `p_air` is shape_atmosphere's {"phi_0", "p_0", "rt_over_m"}, the air the water stands under, and
	// `p_g_rest` the derive's gravity.
	static void seed(Object *p_field, const Dictionary &p_air, const PackedFloat32Array &p_g_rest);
	// The volume share of each cell that is rock below the water table.
	static PackedFloat32Array saturated_share(Object *p_field);
	// Regolith cells, how many carry pore water, and how many hold dry pores with no gas in them.
	static Dictionary wetness(Object *p_field);

protected:
	static void _bind_methods();
};

} // namespace godot

#endif // LOCAL_AGENTS_LA_FIELD_HYDROSPHERE_SEED_HPP
