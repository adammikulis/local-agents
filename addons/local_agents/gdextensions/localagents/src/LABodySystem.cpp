#include "LABodySystem.hpp"

#include "LAFieldCellMass.hpp"
#include "LAPhysicalRead.hpp"
#include "LAPlanetTables.hpp"
#include "LAScriptCall.hpp"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>

#include <cmath>

using namespace godot;

namespace {

const char *GEOMETRY_GD = "res://addons/local_agents/sim/material/FieldGeometry3D.gd";
const char *FIELD_GD = "res://addons/local_agents/sim/material/MaterialField3D.gd";

// Cited measurements of OUR system, which is why none of them belongs in LAPhysical.
constexpr double SOLAR_MASS_KG = 1.98847e30;        // IAU 2015 B3 nominal solar mass
constexpr double SOLAR_LUMINOSITY_W = 3.828e26;     // IAU 2015 B3 nominal solar luminosity
constexpr double SOLAR_RADIUS_M = 6.957e8;          // IAU 2015 B3 nominal solar radius
// Age of the system, years (Connelly et al. 2012, Science 338:651, CAI Pb-Pb).
constexpr double SOLAR_SYSTEM_AGE_YEARS = 4.567e9;

constexpr double EARTH_MASS_KG = 5.97217e24;        // IAU 2015 B3 nominal terrestrial mass
constexpr double LUNAR_MASS_KG = 7.346e22;          // Williams et al. 2014, LLR

// Total angular momentum of the Earth-Moon pair. Tides move it between spin and orbit; they do not change
// the sum, so this one number holds for the epoch as it does for today (Canup 2012, Science 338:1052;
// Touma & Wisdom 1994, AJ 108:1943).
constexpr double EARTH_MOON_ANGULAR_MOMENTUM_KG_M2_S = 3.5e34;

// The Moon just after the accretion disc cleared, metres (Canup 2004, Icarus 168:433). An INITIAL
// POSITION, not a property: it is where the body starts, and the tides move it from there.
constexpr double LUNAR_SEPARATION_AT_EPOCH_M = 2.42e7;

// Semi-major axis of the planet's orbit, metres. The au is exact by definition (IAU 2012 B2).
constexpr double ASTRONOMICAL_UNIT_M = 1.495978707e11;

// Young-sun XUV (1-1200 A), erg cm^-2 s^-1 at 1 au for a sun tau Gyr old, valid past 0.1 Gyr
// (Ribas et al. 2005, ApJ 622:680). Carried as a LUMINOSITY so no body's orbit is baked into it.
constexpr double XUV_1AU_1GYR_W_M2 = 0.0297;
// The tau exponent of the fit above (Ribas et al. 2005).
constexpr double XUV_AGE_EXPONENT = 1.23;

double circular_speed(double p_total_mass_kg, double p_separation_m) {
	return std::sqrt(la_physical("GRAVITATIONAL_CONSTANT") * p_total_mass_kg
			/ MAX(p_separation_m, 1.0));
}

// Orbital angular momentum of a circular two-body pair about their barycentre.
double circular_orbit_angular_momentum(double p_a, double p_b, double p_separation_m) {
	const double reduced = p_a * p_b / MAX(p_a + p_b, 1.0);
	return reduced * std::sqrt(la_physical("GRAVITATIONAL_CONSTANT") * (p_a + p_b) * p_separation_m);
}

} // namespace

// --- LAOrbitState ------------------------------------------------------------------------------------

void LAOrbitState::set_position(const Vector3 &p) {
	px = p.x;
	py = p.y;
	pz = p.z;
}

void LAOrbitState::set_velocity(const Vector3 &v) {
	vx = v.x;
	vy = v.y;
	vz = v.z;
}

Vector3 LAOrbitState::position() const {
	return Vector3(px, py, pz);
}

Vector3 LAOrbitState::velocity() const {
	return Vector3(vx, vy, vz);
}

double LAOrbitState::distance() const {
	return std::sqrt(px * px + py * py + pz * pz);
}

double LAOrbitState::speed() const {
	return std::sqrt(vx * vx + vy * vy + vz * vz);
}

void LAOrbitState::advance(const Vector3 &p_accel, double p_dt) {
	vx += double(p_accel.x) * p_dt;
	vy += double(p_accel.y) * p_dt;
	vz += double(p_accel.z) * p_dt;
	px += vx * p_dt;
	py += vy * p_dt;
	pz += vz * p_dt;
}

void LAOrbitState::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_position", "p"), &LAOrbitState::set_position);
	ClassDB::bind_method(D_METHOD("set_velocity", "v"), &LAOrbitState::set_velocity);
	ClassDB::bind_method(D_METHOD("position"), &LAOrbitState::position);
	ClassDB::bind_method(D_METHOD("velocity"), &LAOrbitState::velocity);
	ClassDB::bind_method(D_METHOD("distance"), &LAOrbitState::distance);
	ClassDB::bind_method(D_METHOD("speed"), &LAOrbitState::speed);
	ClassDB::bind_method(D_METHOD("advance", "accel", "dt"), &LAOrbitState::advance);
#define LA_ORBIT_AXIS(m)                                                            \
	ClassDB::bind_method(D_METHOD("set_" #m, "v"), &LAOrbitState::set_##m);          \
	ClassDB::bind_method(D_METHOD("get_" #m), &LAOrbitState::get_##m);               \
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, #m), "set_" #m, "get_" #m)
	LA_ORBIT_AXIS(px);
	LA_ORBIT_AXIS(py);
	LA_ORBIT_AXIS(pz);
	LA_ORBIT_AXIS(vx);
	LA_ORBIT_AXIS(vy);
	LA_ORBIT_AXIS(vz);
#undef LA_ORBIT_AXIS
}

// --- LABodySeeds -------------------------------------------------------------------------------------

double LABodySeeds::astronomical_unit_m() {
	return ASTRONOMICAL_UNIT_M;
}

Vector3 LABodySeeds::spin_axis() {
	return Vector3(0.40, 0.92, 0.0);
}

// Angular momentum is carried as a UNIT AXIS and a MAGNITUDE, never as one Vector3: Vector3 is binary32,
// and squaring a component of order 1e34 to take a length overflows it to infinity. The spin RATE is then
// an output of whatever inertia the seeded matter turns out to have.
Dictionary LABodySeeds::rows() {
	const double moon_orbit_l = circular_orbit_angular_momentum(
			EARTH_MASS_KG, LUNAR_MASS_KG, LUNAR_SEPARATION_AT_EPOCH_M);
	// What the pair's conserved total leaves the planet to spin with. Its DAY is that over the inertia the
	// seeded matter turns out to have, so the day length is an output.
	const double spin_l = EARTH_MOON_ANGULAR_MOMENTUM_KG_M2_S - moon_orbit_l;
	const double v_orbit = circular_speed(
			SOLAR_MASS_KG + EARTH_MASS_KG + LUNAR_MASS_KG, ASTRONOMICAL_UNIT_M);
	const double v_moon = circular_speed(EARTH_MASS_KG + LUNAR_MASS_KG, LUNAR_SEPARATION_AT_EPOCH_M);
	// The Moon starts in the planet's EQUATORIAL plane, which is what a giant impact leaves behind; the
	// inclination it has today is something the tides did to it, not something it was given.
	const Vector3 spin = spin_axis().normalized();
	const Vector3 moon_dir = spin.cross(
			std::abs(spin.x) < 0.9 ? Vector3(1, 0, 0) : Vector3(0, 1, 0)).normalized();

	Dictionary star;
	star["mass_kg"] = SOLAR_MASS_KG;
	star["luminosity_w"] = luminosity_at_epoch_w();
	star["xuv_luminosity_w"] = xuv_luminosity_at_epoch_w();
	star["radius_m"] = SOLAR_RADIUS_M;
	star["position_m"] = Vector3(ASTRONOMICAL_UNIT_M, 0.0, 0.0);
	star["velocity_m_s"] = Vector3();
	star["spin_axis"] = Vector3();
	star["spin_l_kg_m2_s"] = 0.0;
	star["gridded"] = false;

	Dictionary planet;
	planet["mass_kg"] = EARTH_MASS_KG;
	planet["position_m"] = Vector3();
	planet["velocity_m_s"] = Vector3(0.0, 0.0, v_orbit);
	planet["spin_axis"] = spin;
	planet["spin_l_kg_m2_s"] = spin_l;
	planet["gridded"] = true;

	Dictionary moon;
	moon["mass_kg"] = LUNAR_MASS_KG;
	moon["position_m"] = moon_dir * LUNAR_SEPARATION_AT_EPOCH_M;
	moon["velocity_m_s"] = spin.cross(moon_dir).normalized() * v_moon;
	moon["spin_axis"] = Vector3();
	moon["spin_l_kg_m2_s"] = 0.0;
	moon["gridded"] = false;

	Dictionary out;
	out["star"] = star;
	out["planet"] = planet;
	out["moon"] = moon;
	return out;
}

Dictionary LABodySeeds::of(const String &p_key) {
	return rows().get(p_key, Dictionary());
}

// Gough 1981 (Solar Phys. 74:21): L(t)/L0 = 1 / (1 + (2/5)(1 - t/t0)).
double LABodySeeds::luminosity_at_epoch_w() {
	return SOLAR_LUMINOSITY_W
			/ (1.0 + 0.4 * (la_physical("PLANET_EPOCH_YEARS_BEFORE_PRESENT") / SOLAR_SYSTEM_AGE_YEARS));
}

double LABodySeeds::star_age_at_epoch_gyr() {
	return (SOLAR_SYSTEM_AGE_YEARS - la_physical("PLANET_EPOCH_YEARS_BEFORE_PRESENT")) / 1.0e9;
}

// The 1-au flux Ribas measured, turned back into the luminosity that produced it.
double LABodySeeds::xuv_luminosity_at_epoch_w() {
	const double flux_1au = XUV_1AU_1GYR_W_M2 * std::pow(star_age_at_epoch_gyr(), -XUV_AGE_EXPONENT);
	return flux_1au * 4.0 * Math::PI * ASTRONOMICAL_UNIT_M * ASTRONOMICAL_UNIT_M;
}

double LABodySeeds::irradiance_w_m2(double p_luminosity_w, double p_separation_m) {
	const double r = MAX(p_separation_m, 1.0);
	return p_luminosity_w / (4.0 * Math::PI * r * r);
}

Vector3 LABodySeeds::spin_axis_of(const String &p_key) {
	const Vector3 a = of(p_key).get("spin_axis", Vector3());
	return a.length() > 0.0 ? a.normalized() : Vector3();
}

double LABodySeeds::spin_l_of(const String &p_key) {
	return double(of(p_key).get("spin_l_kg_m2_s", 0.0));
}

double LABodySeeds::seed_radius_m(const String &p_key) {
	const double m = double(of(p_key).get("mass_kg", 0.0));
	if (m <= 0.0) {
		return -1.0;
	}
	const double t_c = double(la_gd_const(FIELD_GD, "INITIAL_TEMP"));
	const double r = LAPlanetComposition::radius_for_mass(m, t_c);
	return (std::isfinite(r) && r > 0.0) ? r : -1.0;
}

void LABodySeeds::_bind_methods() {
	ClassDB::bind_static_method("LABodySeeds", D_METHOD("astronomical_unit_m"),
			&LABodySeeds::astronomical_unit_m);
	ClassDB::bind_static_method("LABodySeeds", D_METHOD("spin_axis"), &LABodySeeds::spin_axis);
	ClassDB::bind_static_method("LABodySeeds", D_METHOD("rows"), &LABodySeeds::rows);
	ClassDB::bind_static_method("LABodySeeds", D_METHOD("of", "key"), &LABodySeeds::of);
	ClassDB::bind_static_method("LABodySeeds", D_METHOD("luminosity_at_epoch_w"),
			&LABodySeeds::luminosity_at_epoch_w);
	ClassDB::bind_static_method("LABodySeeds", D_METHOD("star_age_at_epoch_gyr"),
			&LABodySeeds::star_age_at_epoch_gyr);
	ClassDB::bind_static_method("LABodySeeds", D_METHOD("xuv_luminosity_at_epoch_w"),
			&LABodySeeds::xuv_luminosity_at_epoch_w);
	ClassDB::bind_static_method("LABodySeeds", D_METHOD("irradiance_w_m2", "luminosity_w", "separation_m"),
			&LABodySeeds::irradiance_w_m2);
	ClassDB::bind_static_method("LABodySeeds", D_METHOD("spin_axis_of", "key"),
			&LABodySeeds::spin_axis_of);
	ClassDB::bind_static_method("LABodySeeds", D_METHOD("spin_l_of", "key"), &LABodySeeds::spin_l_of);
	ClassDB::bind_static_method("LABodySeeds", D_METHOD("seed_radius_m", "key"),
			&LABodySeeds::seed_radius_m);
}

// --- LABodyMeasure -----------------------------------------------------------------------------------

bool LABodyMeasure::measured() const {
	return mass_kg > 0.0 && surface_r_m > 0.0;
}

void LABodyMeasure::measure(Object *p_field, const Vector3 &p_spin_axis) {
	mass_kg = -1.0;
	surface_r_m = -1.0;
	inertia_kg_m2 = -1.0;
	gas_constant_j_kgk = -1.0;
	mass_by_channel = Dictionary();
	if (!p_field) {
		return;
	}
	Object *grid = Object::cast_to<Object>(p_field->get("_grid"));
	const int cc = int(p_field->get("_cell_count"));
	if (!grid || cc <= 0) {
		return;
	}
	const PackedByteArray solid = p_field->get("_solid");
	if (solid.size() != cc) {
		return;
	}
	const Array mirrors = LAFieldCellMass3D::mirrors(p_field);
	const Array gases = LAFieldCellMass3D::gas_mirrors(p_field);
	if (mirrors.is_empty()) {
		return;
	}
	const PackedStringArray names = LAFieldCellMass3D::mirror_names(p_field);
	PackedFloat64Array per;
	per.resize(mirrors.size());
	Array cargs;
	cargs.append(p_field);
	const Vector3 centre = la_call_gd(GEOMETRY_GD, "centre", cargs);
	const Vector3 n = p_spin_axis.normalized();
	double m_acc = 0.0;
	double r_max = 0.0;
	double i_acc = 0.0;
	double moles = 0.0;
	double gas_kg = 0.0;
	for (int c = 0; c < cc; c++) {
		const double vol = double(grid->call("cell_volume", c));
		const Vector3 r = Vector3(grid->call("cell_world_pos", c)) - centre;
		double cell_kg = 0.0;
		for (int k = 0; k < mirrors.size(); k++) {
			const Array pair = mirrors[k];
			const PackedFloat32Array arr = pair[0];
			const double kg = MAX(double(arr[c]), 0.0) * double(pair[1]) * vol;
			per[k] = per[k] + kg;
			cell_kg += kg;
		}
		m_acc += cell_kg;
		const Vector3 perp = r - n * r.dot(n);
		i_acc += cell_kg * double(perp.length_squared());
		if (solid[c] != 0) {
			r_max = MAX(r_max, double(r.length()));
			continue;
		}
		for (int g = 0; g < gases.size(); g++) {
			const Array pair = gases[g];
			const PackedFloat32Array arr = pair[0];
			const double g_mol = MAX(double(arr[c]), 0.0) * vol;
			moles += g_mol;
			gas_kg += g_mol * double(pair[1]);
		}
	}
	if (m_acc <= 0.0 || r_max <= 0.0) {
		return;
	}
	mass_kg = m_acc;
	for (int k = 0; k < names.size(); k++) {
		mass_by_channel[names[k]] = per[k];
	}
	surface_r_m = r_max;
	inertia_kg_m2 = i_acc;
	if (moles > 0.0 && gas_kg > 0.0) {
		gas_constant_j_kgk = la_physical("GAS_CONSTANT_J_MOL_K") * moles / gas_kg;
	}
}

double LABodyMeasure::surface_gravity_m_s2() const {
	if (!measured()) {
		return NAN;
	}
	return la_physical("GRAVITATIONAL_CONSTANT") * mass_kg / (surface_r_m * surface_r_m);
}

double LABodyMeasure::angular_velocity_rad_s(double p_spin_l_kg_m2_s) const {
	return inertia_kg_m2 <= 0.0 ? NAN : p_spin_l_kg_m2_s / inertia_kg_m2;
}

double LABodyMeasure::scale_height_at(double p_temp_c, double p_g_m_s2) const {
	if (gas_constant_j_kgk <= 0.0 || !(p_g_m_s2 > 0.0)) {
		return NAN;
	}
	return gas_constant_j_kgk * (p_temp_c + la_physical("KELVIN_OFFSET")) / p_g_m_s2;
}

void LABodyMeasure::_bind_methods() {
	ClassDB::bind_method(D_METHOD("measured"), &LABodyMeasure::measured);
	ClassDB::bind_method(D_METHOD("measure", "field", "spin_axis"), &LABodyMeasure::measure);
	ClassDB::bind_method(D_METHOD("surface_gravity_m_s2"), &LABodyMeasure::surface_gravity_m_s2);
	ClassDB::bind_method(D_METHOD("angular_velocity_rad_s", "spin_l_kg_m2_s"),
			&LABodyMeasure::angular_velocity_rad_s);
	ClassDB::bind_method(D_METHOD("scale_height_at", "temp_c", "g_m_s2"),
			&LABodyMeasure::scale_height_at);
#define LA_MEASURE_READING(m, t)                                              \
	ClassDB::bind_method(D_METHOD("get_" #m), &LABodyMeasure::get_##m);        \
	ADD_PROPERTY(PropertyInfo(t, #m), "", "get_" #m)
	LA_MEASURE_READING(mass_kg, Variant::FLOAT);
	LA_MEASURE_READING(surface_r_m, Variant::FLOAT);
	LA_MEASURE_READING(inertia_kg_m2, Variant::FLOAT);
	LA_MEASURE_READING(gas_constant_j_kgk, Variant::FLOAT);
	LA_MEASURE_READING(mass_by_channel, Variant::DICTIONARY);
#undef LA_MEASURE_READING
}
