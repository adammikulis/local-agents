#ifndef LOCAL_AGENTS_LA_GRAVITY_POTENTIAL_HPP
#define LOCAL_AGENTS_LA_GRAVITY_POTENTIAL_HPP

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>

namespace godot {

// THE POTENTIAL A CPU READER SEES. The device carries the DEVIATION from the monopole reference the
// solve stated it against, because float32 cannot hold tens of MJ/kg and the second differences the
// Laplacian is made of at the same time; this puts the two back together in double.
class LAGravityPotential : public RefCounted {
	GDCLASS(LAGravityPotential, RefCounted);

public:
	static PackedFloat64Array phi_abs(Object *p_grid, const PackedFloat32Array &p_dev,
			const PackedFloat32Array &p_moments, double p_g_si);

protected:
	static void _bind_methods();
};

} // namespace godot

#endif // LOCAL_AGENTS_LA_GRAVITY_POTENTIAL_HPP
