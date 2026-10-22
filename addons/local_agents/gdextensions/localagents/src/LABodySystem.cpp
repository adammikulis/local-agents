#include "LABodySystem.hpp"

#include "LAColumnRadiation.hpp"
#include "LAFieldStateCache.hpp"
#include "LAFieldCellMass.hpp"
#include "LAFieldLithostaticSeed.hpp"
#include "LAPhysicalRead.hpp"
#include "LAPlanetTables.hpp"
#include "LAScriptCall.hpp"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>

#include <cmath>

using namespace godot;

namespace {

const char *GEOMETRY_GD = "res://addons/local_agents/sim/material/FieldGeometry3D.gd";

// Cited measurements of OUR system, which is why none of them belongs in LAPhysical.
constexpr double SOLAR_MASS_KG = 1.98847e30;        // IAU 2015 B3 nominal solar mass
constexpr double SOLAR_LUMINOSITY_W = 3.828e26;     // IAU 2015 B3 nominal solar luminosity
constexpr double SOLAR_RADIUS_M = 6.957e8;          // IAU 2015 B3 nominal solar radius
// Age of the system, years (Connelly et al. 2012, Science 338:651, CAI Pb-Pb).
constexpr double SOLAR_SYSTEM_AGE_YEARS = 4.567e9;

constexpr double EARTH_MASS_KG = 5.97217e24;        // IAU 2015 B3 nominal terrestrial mass
constexpr double LUNAR_MASS_KG = 7.346e22;          // Williams et al. 2014, LLR
// Water in the whole hydrosphere, kg: oceans, ice caps, groundwater, lakes and the air
// (Gleick 1996, Water in Crisis, Table 2.1).
constexpr double EARTH_HYDROSPHERE_KG = 1.386e21;
// The share of it standing in pore space rather than on the surface (Gleick 1996, Table 2.1).
constexpr double EARTH_GROUNDWATER_KG = 2.34e19;
// One bar in pascals, exact by definition.
constexpr double BAR_PA = 1.0e5;
// Partial pressure of N2 over the Archean surface, bar: 0.5 to 1.1 from the isotopic and noble-gas
// record of quartz-hosted fluid inclusions at 3.5 Ga (Marty et al. 2013, Science 342:101). The bulk
// silicate Earth's nitrogen budget holds the atmosphere inside that bound over the Hadean too
// (Marty 2012, EPSL 313:56), and today's 0.78 bar stands inside it.
constexpr double ARCHEAN_PN2_LOW_BAR = 0.5;
constexpr double ARCHEAN_PN2_HIGH_BAR = 1.1;
constexpr double ARCHEAN_PN2_BAR = 0.5 * (ARCHEAN_PN2_LOW_BAR + ARCHEAN_PN2_HIGH_BAR);

// Obliquity of the planet's spin, degrees: the mean obliquity of the ecliptic at J2000, 23 deg 26 min
// 21.406 sec (IAU 2006 precession, IERS Conventions 2010, Table 5.1). The DECISION that it is also the
// 4.4 Ga value is docs/MODEL_PARAMETERS.md's; the epoch's obliquity is not measured.
constexpr double PLANET_OBLIQUITY_DEG = 23.439279;

// The orbital plane, as the two directions that span it: the star from the planet, and the way the
// planet runs. The orbital normal and the spin axis are both read off these.
const Vector3 ORBIT_STAR_DIR(1.0, 0.0, 0.0);
const Vector3 ORBIT_VELOCITY_DIR(0.0, 0.0, 1.0);

// Total angular momentum of the Earth-Moon pair. Tides move it between spin and orbit; they do not change
// the sum, so this one number holds for the epoch as it does for today (Canup 2012, Science 338:1052;
// Touma & Wisdom 1994, AJ 108:1943).
constexpr double EARTH_MOON_ANGULAR_MOMENTUM_KG_M2_S = 3.5e34;

// The Moon just after the accretion disc cleared, metres (Canup 2004, Icarus 168:433). An INITIAL
// POSITION, not a property: it is where the body starts, and the tides move it from there.
constexpr double LUNAR_SEPARATION_AT_EPOCH_M = 2.42e7;

// Semi-major axis of the planet's orbit, metres. The au is exact by definition (IAU 2012 B2).
constexpr double ASTRONOMICAL_UNIT_M = 1.495978707e11;

// Young-sun XUV (1-1200 A) at 1 au for a sun tau Gyr old, valid past 0.1 Gyr: Ribas et al. 2005,
// ApJ 622:680, 29.7 erg cm^-2 s^-1 in SI. Carried as a LUMINOSITY so no body's orbit is baked into it.
constexpr double XUV_1AU_1GYR_W_M2 = 0.0297;   // W/m^2
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

// The matter budget each body is given. One declaration: the rows below and the radius solve read it.
double body_mass_kg(const String &p_key) {
	if (p_key == "star") {
		return SOLAR_MASS_KG;
	}
	if (p_key == "planet") {
		return EARTH_MASS_KG;
	}
	if (p_key == "moon") {
		return LUNAR_MASS_KG;
	}
	return 0.0;
}

// What the seed's surface temperature, radius and surface pressure come out at together.
struct PlanetSeed {
	double t_c = NAN;
	double r_m = NAN;
	double p_surface_pa = NAN;
};

// THE SEED'S OWN SURFACE, solved rather than declared: what the epoch's star delivers to the seeded
// surface less what it reflects, plus what the body's own decay delivers from below, against the
// longwave leaving the seeded column. The radius and the surface gravity that balance is taken at
// follow from the temperature it returns, so the pair is iterated until it stops moving.
const PlanetSeed &planet_seed() {
	static PlanetSeed s;
	static bool solved = false;
	if (solved) {
		return s;
	}
	solved = true;
	// A function of the constants alone, so it is read back when this content has been solved before.
	const PackedFloat64Array none;
	const PackedFloat64Array stored = LAFieldStateCache::pure_load("planet_seed", none);
	if (stored.size() == 3) {
		s.t_c = stored[0];
		s.r_m = stored[1];
		s.p_surface_pa = stored[2];
		return s;
	}
	const Dictionary x = LAFieldLithostaticSeed::seeded_air_mole_fractions();
	const double x_n2 = double(x.get("n2", 0.0));
	if (!(x_n2 > 0.0)) {
		UtilityFunctions::push_error("LABodySeeds: the seeded air carries no N2, so its cited partial "
				"pressure states no surface pressure.");
		return s;
	}
	// The column stands at the pressure N2's cited partial pressure implies over N2's own share of it.
	s.p_surface_pa = ARCHEAN_PN2_BAR * BAR_PA / x_n2;
	// A sphere radiates over four times the disc that intercepts the beam.
	const double absorbed = (1.0 - LABodySeeds::surface_albedo())
			* LABodySeeds::irradiance_w_m2(LABodySeeds::luminosity_at_epoch_w(), ASTRONOMICAL_UNIT_M)
			/ 4.0;
	const double g_const = la_physical("GRAVITATIONAL_CONSTANT");
	const double kelvin = la_physical("KELVIN_OFFSET");
	double t_c = 0.0;
	double r = 0.0;
	// Until the radius the balance is taken at stops moving. The pass count bounds an oscillation in
	// the last bits; the loop settles in two.
	for (int i = 0; i < 8; i++) {
		const double r_next = LAPlanetComposition::radius_for_mass(EARTH_MASS_KG, t_c);
		if (!(std::isfinite(r_next) && r_next > 0.0)) {
			UtilityFunctions::push_error("LABodySeeds: the composition solves no radius, so the surface "
					"balance has no gravity to stand the column in.");
			return s;
		}
		if (r_next == r) {
			break;
		}
		r = r_next;
		const double net_in = absorbed + LAPlanetComposition::surface_heat_flux_w_m2(EARTH_MASS_KG, r);
		t_c = LAColumnRadiation::equilibrium_temp_k(net_in, x, s.p_surface_pa,
					  g_const * EARTH_MASS_KG / (r * r))
				- kelvin;
		if (!std::isfinite(t_c)) {
			UtilityFunctions::push_error("LABodySeeds: the seeded column radiates nothing that balances "
					"what reaches it inside the band table's range, so the surface has no temperature.");
			return s;
		}
	}
	s.t_c = t_c;
	s.r_m = r;
	PackedFloat64Array answer;
	answer.push_back(s.t_c);
	answer.push_back(s.r_m);
	answer.push_back(s.p_surface_pa);
	LAFieldStateCache::pure_store("planet_seed", none, answer);
	return s;
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

double LABodySeeds::obliquity_deg() {
	return PLANET_OBLIQUITY_DEG;
}

// r x v of the planet about the star, off the two directions that span its orbital plane.
Vector3 LABodySeeds::orbital_normal() {
	return (-ORBIT_STAR_DIR).cross(ORBIT_VELOCITY_DIR).normalized();
}

// The orbital normal tipped by the obliquity, towards the star direction. Which way it is tipped inside
// the orbital plane is a phase of the year, not a measurement.
Vector3 LABodySeeds::spin_axis() {
	const double a = Math::deg_to_rad(PLANET_OBLIQUITY_DEG);
	return (orbital_normal() * std::cos(a) + ORBIT_STAR_DIR * std::sin(a)).normalized();
}

// The surface the seeded planet turns to the star: its ground and its water, over the share of the solid
// surface each covers under the hypsometric curve the ground is shaped from.
double LABodySeeds::surface_albedo() {
	const double land = la_physical("HYPSOMETRY_LAND_AREA_FRACTION");
	return land * la_physical("ALBEDO_BARE_GROUND") + (1.0 - land) * la_physical("ALBEDO_OCEAN");
}

double LABodySeeds::surface_temp_c() {
	return planet_seed().t_c;
}

double LABodySeeds::surface_pressure_pa() {
	return planet_seed().p_surface_pa;
}

// The N2 standing over that surface at its cited partial pressure: p A / g.
double LABodySeeds::atmosphere_n2_kg() {
	const double r = seed_radius_m("planet");
	if (!(r > 0.0)) {
		return 0.0;
	}
	const double g = la_physical("GRAVITATIONAL_CONSTANT") * EARTH_MASS_KG / (r * r);
	return ARCHEAN_PN2_BAR * BAR_PA * 4.0 * Math::PI * r * r / g;
}

PackedFloat64Array LABodySeeds::archean_pn2_bound_bar() {
	PackedFloat64Array out;
	out.push_back(ARCHEAN_PN2_LOW_BAR);
	out.push_back(ARCHEAN_PN2_HIGH_BAR);
	return out;
}

// Angular momentum is carried as a UNIT AXIS and a MAGNITUDE, never as one Vector3: Vector3 is binary32,
// and squaring a component of order 1e34 to take a length overflows it to infinity. The spin RATE is then
// an output of whatever inertia the seeded matter turns out to have.
Dictionary LABodySeeds::rows() {
	const double moon_orbit_l = circular_orbit_angular_momentum(
			body_mass_kg("planet"), body_mass_kg("moon"), LUNAR_SEPARATION_AT_EPOCH_M);
	// What the pair's conserved total leaves the planet to spin with. Its DAY is that over the inertia the
	// seeded matter turns out to have, so the day length is an output.
	const double spin_l = EARTH_MOON_ANGULAR_MOMENTUM_KG_M2_S - moon_orbit_l;
	const double v_orbit = circular_speed(
			body_mass_kg("star") + body_mass_kg("planet") + body_mass_kg("moon"), ASTRONOMICAL_UNIT_M);
	const double v_moon = circular_speed(body_mass_kg("planet") + body_mass_kg("moon"),
			LUNAR_SEPARATION_AT_EPOCH_M);
	// The Moon starts in the planet's EQUATORIAL plane, which is what a giant impact leaves behind; the
	// inclination it has today is something the tides did to it, not something it was given.
	const Vector3 spin = spin_axis().normalized();
	const Vector3 moon_dir = spin.cross(
			std::abs(spin.x) < 0.9 ? Vector3(1, 0, 0) : Vector3(0, 1, 0)).normalized();

	Dictionary star;
	star["mass_kg"] = body_mass_kg("star");
	star["luminosity_w"] = luminosity_at_epoch_w();
	star["xuv_luminosity_w"] = xuv_luminosity_at_epoch_w();
	star["radius_m"] = SOLAR_RADIUS_M;
	star["position_m"] = ORBIT_STAR_DIR * ASTRONOMICAL_UNIT_M;
	star["velocity_m_s"] = Vector3();
	star["spin_axis"] = Vector3();
	star["spin_l_kg_m2_s"] = 0.0;
	star["gridded"] = false;

	Dictionary planet;
	planet["mass_kg"] = body_mass_kg("planet");
	planet["hydrosphere_kg"] = EARTH_HYDROSPHERE_KG;
	planet["groundwater_kg"] = EARTH_GROUNDWATER_KG;
	planet["atmosphere_n2_kg"] = atmosphere_n2_kg();
	planet["surface_temp_c"] = surface_temp_c();
	planet["position_m"] = Vector3();
	planet["velocity_m_s"] = ORBIT_VELOCITY_DIR * v_orbit;
	planet["spin_axis"] = spin;
	planet["spin_l_kg_m2_s"] = spin_l;
	planet["gridded"] = true;

	Dictionary moon;
	moon["mass_kg"] = body_mass_kg("moon");
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
	// One bisection per body per run: the mass and the composition it is solved against do not change.
	static Dictionary memo;
	if (memo.has(p_key)) {
		return double(memo[p_key]);
	}
	if (p_key == "planet") {
		const double r_planet = planet_seed().r_m;
		memo[p_key] = (std::isfinite(r_planet) && r_planet > 0.0) ? r_planet : -1.0;
		return double(memo[p_key]);
	}
	const double m = body_mass_kg(p_key);
	if (m <= 0.0) {
		return -1.0;
	}
	const double r = LAPlanetComposition::radius_for_mass(m, planet_seed().t_c);
	const double out = (std::isfinite(r) && r > 0.0) ? r : -1.0;
	memo[p_key] = out;
	return out;
}

void LABodySeeds::_bind_methods() {
	ClassDB::bind_static_method("LABodySeeds", D_METHOD("astronomical_unit_m"),
			&LABodySeeds::astronomical_unit_m);
	ClassDB::bind_static_method("LABodySeeds", D_METHOD("spin_axis"), &LABodySeeds::spin_axis);
	ClassDB::bind_static_method("LABodySeeds", D_METHOD("obliquity_deg"), &LABodySeeds::obliquity_deg);
	ClassDB::bind_static_method("LABodySeeds", D_METHOD("orbital_normal"), &LABodySeeds::orbital_normal);
	ClassDB::bind_static_method("LABodySeeds", D_METHOD("surface_albedo"), &LABodySeeds::surface_albedo);
	ClassDB::bind_static_method("LABodySeeds", D_METHOD("surface_temp_c"), &LABodySeeds::surface_temp_c);
	ClassDB::bind_static_method("LABodySeeds", D_METHOD("surface_pressure_pa"),
			&LABodySeeds::surface_pressure_pa);
	ClassDB::bind_static_method("LABodySeeds", D_METHOD("atmosphere_n2_kg"),
			&LABodySeeds::atmosphere_n2_kg);
	ClassDB::bind_static_method("LABodySeeds", D_METHOD("archean_pn2_bound_bar"),
			&LABodySeeds::archean_pn2_bound_bar);
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
	double v_rock = 0.0;
	double i_acc = 0.0;
	const PackedVector3Array la_cw = grid->get("centres");
	const PackedFloat32Array la_cv = grid->call("cell_volumes");
	const PackedFloat32Array rock = p_field->get("_rock_fraction");
	const bool has_rock = rock.size() == cc;
	for (int c = 0; c < cc; c++) {
		const double vol = double(la_cv[c]);
		const Vector3 r = la_cw[c] - centre;
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
		// The crust's own volume, sub-cell: what the radius below is the radius OF.
		v_rock += (has_rock ? MAX(double(rock[c]), 0.0) : (solid[c] != 0 ? 1.0 : 0.0)) * vol;
	}
	if (m_acc <= 0.0 || v_rock <= 0.0) {
		return;
	}
	mass_kg = m_acc;
	for (int k = 0; k < names.size(); k++) {
		mass_by_channel[names[k]] = per[k];
	}
	// A WINDOW ON A BODY IS NOT THE BODY. A slice holds a slab of it, so the mass it sums carries no
	// moment about the body's axis and no crust volume the body's radius could come out of: both stay
	// UNMEASURED rather than reading as the slab's own.
	const bool whole = p_field->get("_slice").get_type() == Variant::NIL;
	// THE VOLUMETRIC MEAN RADIUS of the crust, the radius published for a planet: the sphere holding the
	// solid volume that was seeded. A peak is not a radius, and gravity is the solve's field, not GM/r^2.
	surface_r_m = whole ? std::cbrt(3.0 * v_rock / (4.0 * Math::PI)) : -1.0;
	inertia_kg_m2 = whole ? i_acc : -1.0;
}

double LABodyMeasure::angular_velocity_rad_s(double p_spin_l_kg_m2_s) const {
	return inertia_kg_m2 <= 0.0 ? NAN : p_spin_l_kg_m2_s / inertia_kg_m2;
}

void LABodyMeasure::_bind_methods() {
	ClassDB::bind_method(D_METHOD("measured"), &LABodyMeasure::measured);
	ClassDB::bind_method(D_METHOD("measure", "field", "spin_axis"), &LABodyMeasure::measure);
	ClassDB::bind_method(D_METHOD("angular_velocity_rad_s", "spin_l_kg_m2_s"),
			&LABodyMeasure::angular_velocity_rad_s);
#define LA_MEASURE_READING(m, t)                                              \
	ClassDB::bind_method(D_METHOD("get_" #m), &LABodyMeasure::get_##m);        \
	ADD_PROPERTY(PropertyInfo(t, #m), "", "get_" #m)
	LA_MEASURE_READING(mass_kg, Variant::FLOAT);
	LA_MEASURE_READING(surface_r_m, Variant::FLOAT);
	LA_MEASURE_READING(inertia_kg_m2, Variant::FLOAT);
	LA_MEASURE_READING(mass_by_channel, Variant::DICTIONARY);
#undef LA_MEASURE_READING
}
