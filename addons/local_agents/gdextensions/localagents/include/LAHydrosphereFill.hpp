#ifndef LOCAL_AGENTS_LA_HYDROSPHERE_FILL_HPP
#define LOCAL_AGENTS_LA_HYDROSPHERE_FILL_HPP

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/vector3.hpp>

namespace godot {

// THE BODY'S SURFACE WATER, SETTLED ONCE FOR THE SEED: the declared inventory laid over the solved surface
// along an even sweep, lowest ground first, so its free surface is the one equipotential of the body's
// monopole that holds it. The seed places the water off this; from the seal on the field holds it.
class LAHydrosphereFill : public RefCounted {
	GDCLASS(LAHydrosphereFill, RefCounted);

	Object *surface_ = nullptr;
	double free_r_ = NAN;
	PackedFloat64Array ground_r_;

public:
	// Direction `p_i` of an `p_n`-point Fibonacci lattice: even coverage, no clustering at the poles.
	static Vector3 sweep_dir(int p_i, int p_n);
	// The water `p_terrain` settled for the seed through its hydrosphere(); null where it settled none.
	static LAHydrosphereFill *of(Object *p_terrain);
	// `p_surface` answers body_surface_radius(dir); the inventory is `p_body_key`'s surface water, swept over
	// `p_samples` directions.
	void settle(Object *p_surface, const String &p_body_key, int p_samples);
	bool settled() const;
	// The ground's height over the settled water along a body-frame direction, m; negative under water.
	double ground_over_water(const Vector3 &p_dir) const;
	// Along the line p + x up, p taken from the body centre: the x at which it leaves the settled water
	// going up, m; -INF where it never enters it.
	double leaves_water_at(const Vector3 &p_rel, const Vector3 &p_up) const;
	// The settled free surface's radius, m, for the seed that lays the water under it and the karst that
	// opens only over it.
	double free_surface_r() const { return free_r_; }
	// The sweep, and the radius along each of its directions where the condensed matter ends: the ground or
	// the water standing on it.
	int sweep_count() const { return ground_r_.size(); }
	double sweep_condensed_top_r(int p_i) const;

protected:
	static void _bind_methods();
};

} // namespace godot

#endif // LOCAL_AGENTS_LA_HYDROSPHERE_FILL_HPP
