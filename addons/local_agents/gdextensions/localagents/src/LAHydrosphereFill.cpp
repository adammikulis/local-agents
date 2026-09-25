#include "LAHydrosphereFill.hpp"

#include "LABodySystem.hpp"
#include "LAPhysicalRead.hpp"
#include "LASubstances.hpp"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/math.hpp>
#include <godot_cpp/variant/dictionary.hpp>

#include <algorithm>
#include <cmath>

using namespace godot;

Vector3 LAHydrosphereFill::sweep_dir(int p_i, int p_n) {
	const double golden = Math::PI * (3.0 - std::sqrt(5.0));
	const double y = 1.0 - 2.0 * (double(p_i) + 0.5) / double(p_n);
	const double s = std::sqrt(std::max(0.0, 1.0 - y * y));
	return Vector3(std::cos(golden * p_i) * s, y, std::sin(golden * p_i) * s).normalized();
}

LAHydrosphereFill *LAHydrosphereFill::of(Object *p_terrain) {
	if (!p_terrain || !p_terrain->has_method("hydrosphere")) {
		return nullptr;
	}
	const Variant v = p_terrain->call("hydrosphere");
	LAHydrosphereFill *fill = Object::cast_to<LAHydrosphereFill>(static_cast<Object *>(v));
	return (fill && fill->settled()) ? fill : nullptr;
}

// LA_APPROX: water_fill_monopole
void LAHydrosphereFill::settle(Object *p_surface, const String &p_body_key, int p_samples) {
	surface_ = p_surface;
	free_r_ = NAN;
	ground_r_.clear();
	ERR_FAIL_COND_MSG(!p_surface || p_samples < 2, "LAHydrosphereFill: no surface to settle the water over.");
	const Dictionary body = LABodySeeds::of(p_body_key);
	const double water_kg = double(body.get("hydrosphere_kg", 0.0)) - double(body.get("groundwater_kg", 0.0));
	const double kg_m3 = la_physical("MOLAR_MASS_WATER_KG_MOL") * LASubstances::full_mol_m3("h2o");
	ERR_FAIL_COND_MSG(!(water_kg >= 0.0) || !(kg_m3 > 0.0), "LAHydrosphereFill: the body record declares no "
			"surface water it could settle, or water has no density.");
	ground_r_.resize(p_samples);
	double lo = INFINITY, hi = -INFINITY;
	for (int i = 0; i < p_samples; i++) {
		const double r = double(p_surface->call("body_surface_radius", sweep_dir(i, p_samples)));
		ERR_FAIL_COND_MSG(!std::isfinite(r), "LAHydrosphereFill: the surface states no radius along a sweep "
				"direction, so the water has no ground to settle on there.");
		ground_r_.set(i, r);
		lo = std::min(lo, r);
		hi = std::max(hi, r);
	}
	// The volume the ground holds under a free surface at radius R: each direction's share of the sphere's
	// solid angle times the shell between its ground and R.
	const double w = 4.0 * Math::PI / (3.0 * double(p_samples));
	auto held = [&](double p_r) {
		double acc = 0.0;
		for (int i = 0; i < p_samples; i++) {
			const double g = ground_r_[i];
			acc += p_r > g ? (p_r - g) * (p_r * p_r + p_r * g + g * g) : 0.0;
		}
		return w * acc;
	};
	const double want = water_kg / kg_m3;
	// Water enough to drown the highest ground covers every direction, and the shell over it is closed form.
	if (held(hi) < want) {
		double cubes = 0.0;
		for (int i = 0; i < p_samples; i++) {
			cubes += ground_r_[i] * ground_r_[i] * ground_r_[i];
		}
		free_r_ = std::cbrt((want + w * cubes) / (w * double(p_samples)));
		return;
	}
	for (int it = 0; it < 64; it++) {
		const double mid = 0.5 * (lo + hi);
		if (held(mid) < want) {
			lo = mid;
		} else {
			hi = mid;
		}
	}
	free_r_ = 0.5 * (lo + hi);
}

bool LAHydrosphereFill::settled() const {
	return surface_ != nullptr && std::isfinite(free_r_);
}

double LAHydrosphereFill::ground_over_water(const Vector3 &p_dir) const {
	ERR_FAIL_COND_V(!settled(), NAN);
	return double(surface_->call("body_surface_radius", p_dir)) - free_r_;
}

double LAHydrosphereFill::leaves_water_at(const Vector3 &p_rel, const Vector3 &p_up) const {
	const double par = double(p_rel.x) * p_up.x + double(p_rel.y) * p_up.y + double(p_rel.z) * p_up.z;
	const double r2 = double(p_rel.x) * p_rel.x + double(p_rel.y) * p_rel.y + double(p_rel.z) * p_rel.z;
	const double inside = free_r_ * free_r_ - std::max(r2 - par * par, 0.0);
	return (settled() && inside > 0.0) ? std::sqrt(inside) - par : -INFINITY;
}

double LAHydrosphereFill::sweep_condensed_top_r(int p_i) const {
	return std::max(ground_r_[p_i], free_r_);
}

void LAHydrosphereFill::_bind_methods() {
	ClassDB::bind_method(D_METHOD("settle", "surface", "body_key", "samples"), &LAHydrosphereFill::settle);
	ClassDB::bind_method(D_METHOD("settled"), &LAHydrosphereFill::settled);
	ClassDB::bind_method(D_METHOD("free_surface_r"), &LAHydrosphereFill::free_surface_r);
}
