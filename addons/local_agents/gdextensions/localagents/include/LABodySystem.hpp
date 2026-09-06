#ifndef LOCAL_AGENTS_LA_BODY_SYSTEM_HPP
#define LOCAL_AGENTS_LA_BODY_SYSTEM_HPP

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/vector3.hpp>

namespace godot {

// A position and a velocity, in DOUBLES. Vector3 is binary32, whose spacing at one astronomical unit is
// thousands of metres - larger than the error budget of an orbit that has to close.
class LAOrbitState : public RefCounted {
	GDCLASS(LAOrbitState, RefCounted);

	double px = 0.0, py = 0.0, pz = 0.0;
	double vx = 0.0, vy = 0.0, vz = 0.0;

public:
	void set_px(double v) { px = v; }
	double get_px() const { return px; }
	void set_py(double v) { py = v; }
	double get_py() const { return py; }
	void set_pz(double v) { pz = v; }
	double get_pz() const { return pz; }
	void set_vx(double v) { vx = v; }
	double get_vx() const { return vx; }
	void set_vy(double v) { vy = v; }
	double get_vy() const { return vy; }
	void set_vz(double v) { vz = v; }
	double get_vz() const { return vz; }

	void set_position(const Vector3 &p);
	void set_velocity(const Vector3 &v);
	Vector3 position() const;
	Vector3 velocity() const;
	double distance() const;
	double speed() const;
	// Semi-implicit: velocity first, so a bound orbit stays bound instead of gaining energy every
	// revolution the way explicit Euler does.
	void advance(const Vector3 &p_accel, double p_dt);

protected:
	static void _bind_methods();
};

// WHAT A BODY IS GIVEN. Radius, surface gravity, day length, luminosity, insolation and orbital elements
// are not here: they are measured off the substrate or derived from these. `mass_kg` is the matter budget.
class LABodySeeds : public RefCounted {
	GDCLASS(LABodySeeds, RefCounted);

public:
	static double astronomical_unit_m();
	// The angle the spin axis makes with the orbital normal, degrees, and the two vectors it is between.
	static double obliquity_deg();
	static Vector3 orbital_normal();
	// Obliquity: the DIRECTION of the planet's spin angular momentum, an initial condition like any other.
	static Vector3 spin_axis();
	// THE SEED'S SURFACE, solved once: the temperature at which the seeded column radiates what the star
	// and the body's own decay deliver, the pressure its cited N2 stands the air at, and the albedo the
	// balance is taken under. NAN and an error where the balance does not close.
	static double surface_temp_c();
	static double surface_pressure_pa();
	static double surface_albedo();
	// The N2 the seeded atmosphere holds, kg, and the partial-pressure bound it is drawn from, bar.
	static double atmosphere_n2_kg();
	static PackedFloat64Array archean_pn2_bound_bar();
	static Dictionary rows();
	static Dictionary of(const String &p_key);
	static double luminosity_at_epoch_w();
	static double star_age_at_epoch_gyr();
	static double xuv_luminosity_at_epoch_w();
	// Irradiance a body at `separation_m` receives from a star of `luminosity_w`. The whole of insolation:
	// no nominal orbit, no normalisation, so eccentricity and a knocked orbit both show up on their own.
	static double irradiance_w_m2(double p_luminosity_w, double p_separation_m);
	static Vector3 spin_axis_of(const String &p_key);
	static double spin_l_of(const String &p_key);
	// THE RADIUS A BODY OF THIS MASS SETTLES AT, metres: how far the matter spreads once its own weight
	// has squeezed it, solved from the composition's own equation of state. Negative is unmeasured.
	static double seed_radius_m(const String &p_key);

protected:
	static void _bind_methods();
};

// THE BODY'S BULK PROPERTIES, MEASURED in one walk of the field: mass is the matter present, radius is
// where it ends, and inertia is how it is distributed.
// Negative is UNMEASURED, and a reader refuses what it was sizing rather than assuming a planet.
class LABodyMeasure : public RefCounted {
	GDCLASS(LABodyMeasure, RefCounted);

	double mass_kg = -1.0;
	double surface_r_m = -1.0;
	double inertia_kg_m2 = -1.0;
	Dictionary mass_by_channel;

public:
	double get_mass_kg() const { return mass_kg; }
	double get_surface_r_m() const { return surface_r_m; }
	double get_inertia_kg_m2() const { return inertia_kg_m2; }
	// Channel -> kilograms it holds. WHAT THE BODY IS MADE OF: a total nobody can decompose cannot say
	// which channel is wrong when it disagrees with the seed.
	Dictionary get_mass_by_channel() const { return mass_by_channel; }

	bool measured() const;
	// ONE pass. `spin_axis` is the direction the seeded angular momentum points, so the inertia is about
	// the axis the body actually turns on.
	// LA_APPROX: seal_time_inertia
	void measure(Object *p_field, const Vector3 &p_spin_axis);
	double angular_velocity_rad_s(double p_spin_l_kg_m2_s) const;

protected:
	static void _bind_methods();
};

} // namespace godot

#endif // LOCAL_AGENTS_LA_BODY_SYSTEM_HPP
