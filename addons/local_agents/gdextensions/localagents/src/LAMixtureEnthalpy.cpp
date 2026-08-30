#include "LAMixtureEnthalpy.hpp"

#include "LAPhysicalRead.hpp"
#include "LASubstances.hpp"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/math.hpp>
#include <godot_cpp/variant/array.hpp>

#include <algorithm>
#include <cmath>
#include <limits>
#include <vector>

using namespace godot;

namespace {

constexpr double kInf = std::numeric_limits<double>::infinity();

// Doubling steps to bracket the far end past the last boundary, and Illinois iterations on the bracket.
constexpr int kBracketDoublings = 64;
constexpr int kSolveIterations = 120;
constexpr double kBracketSpanC = 100.0;

double prop(const String &p_id, const char *p_key, double p_default) {
	const Dictionary entry = LASubstances::table().get(p_id, Dictionary());
	return double(entry.get(p_key, p_default));
}

} // namespace

// Where this substance's last condensed phase leaves: the frost point below the triple-point pressure,
// the boiling point above it.
double LAMixtureEnthalpy::vapour_boundary_c(const String &p_id, double p_p_pa) {
	if (LASubstances::sublimes_at(p_id, p_p_pa)) {
		return LASubstances::sublimation_c_at(p_id, p_p_pa);
	}
	return LASubstances::boil_c_at(p_id, p_p_pa);
}

// The vapour pressure of the phase actually present: sublimation while the condensate is solid, saturation
// once it is liquid. ONE owner per boundary, both read off this table.
double LAMixtureEnthalpy::vapour_p_at(const String &p_id, double p_t_c, double p_p_pa) {
	const double melt = LASubstances::melt_c_at(p_id, p_p_pa, 0.0);
	if (LASubstances::sublimes_at(p_id, p_p_pa) || (std::isfinite(melt) && p_t_c < melt)) {
		return LASubstances::sublimation_p_at(p_id, p_t_c);
	}
	return LASubstances::saturation_p_at(p_id, p_t_c);
}

// Latent heat to take the condensed phase present at this temperature into the vapour, J/kg.
double LAMixtureEnthalpy::latent_out_of_condensed(const String &p_id, double p_t_c, double p_p_pa) {
	const double melt = LASubstances::melt_c_at(p_id, p_p_pa, 0.0);
	if (LASubstances::sublimes_at(p_id, p_p_pa) || (std::isfinite(melt) && p_t_c < melt)) {
		return LASubstances::latent_sublimation_j_kg(p_id);
	}
	return LASubstances::latent_vaporisation_at(p_id, p_t_c);
}

// THE SATURATION SPLIT AT FIXED VOLUME: the vapour fills the cell's gas room at its own saturation
// pressure, n_v = p_v(T) room / (R T), and the rest stays condensed. A cell has a volume, not a pressure
// it is held at, so boiling is continuous in T and there is no plateau; the total pressure follows.
double LAMixtureEnthalpy::vapour_fraction(const String &p_id, double p_t_c, double p_p_pa, double p_m_kg,
		double p_room_m3) {
	if (p_m_kg <= 0.0 || !std::isfinite(vapour_boundary_c(p_id, p_p_pa))) {
		return 0.0;
	}
	if (p_t_c >= prop(p_id, "critical_t_c", kInf)) {
		return 1.0;
	}
	const double mm = prop(p_id, "molar_mass", 0.0);
	if (p_room_m3 <= 0.0 || mm <= 0.0) {
		return 0.0;
	}
	const double p_v = vapour_p_at(p_id, p_t_c, p_p_pa);
	if (p_v <= 0.0) {
		return 0.0;
	}
	const double t_k = std::max(p_t_c + la_physical("KELVIN_OFFSET"), 1.0);
	return std::min(p_v * p_room_m3 / (la_physical("GAS_CONSTANT_J_MOL_K") * t_k) * mm / p_m_kg, 1.0);
}

// Specific enthalpy of one substance AS IT SITS IN THIS CELL: the condensed curve plus the latent heat of
// the share the room holds as vapour. The condensed curve is read at a pressure that keeps it condensed,
// so the split above is the only place the vapour share is decided. Past the critical point there is one
// fluid and the substance's own curve carries it.
double LAMixtureEnthalpy::specific_enthalpy(const String &p_id, double p_t_c, double p_p_pa, double p_m_kg,
		double p_room_m3) {
	if (!std::isfinite(vapour_boundary_c(p_id, p_p_pa)) || p_t_c >= prop(p_id, "critical_t_c", kInf)) {
		return LASubstances::enthalpy_at(p_id, p_t_c, p_p_pa, 0.0);
	}
	const double f_v = vapour_fraction(p_id, p_t_c, p_p_pa, p_m_kg, p_room_m3);
	const double p_v = vapour_p_at(p_id, p_t_c, p_p_pa);
	const double h = LASubstances::enthalpy_at(p_id, p_t_c, std::max(p_p_pa, p_v * (1.0 + 1.0e-3)), 0.0);
	if (f_v <= 0.0) {
		return h;
	}
	return h + f_v * latent_out_of_condensed(p_id, p_t_c, p_p_pa);
}

// Total enthalpy of the cell at a temperature, J.
double LAMixtureEnthalpy::enthalpy_at(const Dictionary &p_masses, double p_room_m3, double p_t_c,
		double p_p_pa) {
	double h = 0.0;
	const Array ids = p_masses.keys();
	for (int i = 0; i < ids.size(); i++) {
		const String id = ids[i];
		const double m = double(p_masses[ids[i]]);
		if (m > 0.0) {
			h += m * specific_enthalpy(id, p_t_c, p_p_pa, m, p_room_m3);
		}
	}
	return h;
}

// Every phase boundary of every substance present at this pressure, ascending and deduplicated.
PackedFloat64Array LAMixtureEnthalpy::breakpoints(const Dictionary &p_masses, double p_p_pa) {
	std::vector<double> out;
	const Array ids = p_masses.keys();
	for (int i = 0; i < ids.size(); i++) {
		const String id = ids[i];
		if (double(p_masses[ids[i]]) <= 0.0) {
			continue;
		}
		const double cand[4] = { LASubstances::melt_c_at(id, p_p_pa, 0.0),
			LASubstances::liquidus_c_at(id, p_p_pa, 0.0), vapour_boundary_c(id, p_p_pa),
			prop(id, "critical_t_c", kInf) };
		for (double t : cand) {
			if (std::isfinite(t) && std::find(out.begin(), out.end(), t) == out.end()) {
				out.push_back(t);
			}
		}
	}
	std::sort(out.begin(), out.end());
	PackedFloat64Array packed;
	for (double t : out) {
		packed.push_back(t);
	}
	return packed;
}

// The height of the discontinuity at a boundary, J: the fusion step of what is still condensed there.
// Boiling has no step at fixed volume -- the vapour share climbs with the saturation pressure.
Dictionary LAMixtureEnthalpy::jump_at(const Dictionary &p_masses, double p_room_m3, double p_t_b,
		double p_p_pa) {
	Dictionary per_id;
	double total = 0.0;
	const Array ids = p_masses.keys();
	for (int i = 0; i < ids.size(); i++) {
		const String id = ids[i];
		const double m = double(p_masses[ids[i]]);
		if (m <= 0.0) {
			continue;
		}
		double j = 0.0;
		const double solidus = LASubstances::melt_c_at(id, p_p_pa, 0.0);
		const double liquidus = LASubstances::liquidus_c_at(id, p_p_pa, 0.0);
		if (std::isfinite(solidus) && Math::is_equal_approx(solidus, p_t_b)
				&& Math::is_equal_approx(liquidus, p_t_b)) {
			const double l_fus = prop(id, "latent_fusion_j_kg", 0.0);
			j += m * (1.0 - vapour_fraction(id, p_t_b, p_p_pa, m, p_room_m3)) * l_fus;
		}
		if (j > 0.0) {
			per_id[id] = j;
			total += j;
		}
	}
	Dictionary out;
	out["total"] = total;
	out["per_id"] = per_id;
	return out;
}

// THE CELL'S TEMPERATURE from its total enthalpy, ITERATIVE and not closed form: a condensable substance
// is split by its saturation curve, which carries exp(-L / R_v T). Boundaries are walked, a jump the
// enthalpy lands inside PINS the temperature, and the smooth stretch between them is bracketed and solved.
Dictionary LAMixtureEnthalpy::state(const Dictionary &p_masses, double p_room_m3, double p_h_total_j,
		double p_p_pa) {
	double lo = -la_physical("KELVIN_OFFSET");
	double h_lo = enthalpy_at(p_masses, p_room_m3, lo, p_p_pa);
	if (p_h_total_j <= h_lo) {
		return _report(p_masses, p_room_m3, lo, p_p_pa, Dictionary(), false);
	}
	double hi = kInf;
	const PackedFloat64Array bps = breakpoints(p_masses, p_p_pa);
	for (int i = 0; i < bps.size(); i++) {
		const double t_b = bps[i];
		if (t_b <= lo) {
			continue;
		}
		const double h_b = enthalpy_at(p_masses, p_room_m3, t_b, p_p_pa);
		if (p_h_total_j <= h_b) {
			hi = t_b;
			break;
		}
		const Dictionary jump = jump_at(p_masses, p_room_m3, t_b, p_p_pa);
		const double top = h_b + double(jump["total"]);
		if (p_h_total_j < top) {
			return _pinned(p_masses, p_room_m3, t_b, p_p_pa, jump, p_h_total_j - h_b);
		}
		lo = t_b;
		h_lo = top;
	}
	if (!std::isfinite(hi)) {
		// Past the last boundary the curve only rises, so doubling the span always finds the far end.
		double span = kBracketSpanC;
		for (int i = 0; i < kBracketDoublings; i++) {
			hi = lo + span;
			if (enthalpy_at(p_masses, p_room_m3, hi, p_p_pa) >= p_h_total_j) {
				break;
			}
			span *= 2.0;
		}
	}
	return _report(p_masses, p_room_m3,
			_solve(p_masses, p_room_m3, p_h_total_j, p_p_pa, lo, hi), p_p_pa, Dictionary(), false);
}

// Illinois false position over a bracket the boundary walk already proved. Exact in one step on a linear
// segment; the halving keeps an end from sticking where the saturation split makes it curve.
double LAMixtureEnthalpy::_solve(const Dictionary &p_masses, double p_room_m3, double p_h_total_j,
		double p_p_pa, double p_lo, double p_hi) {
	double a = p_lo;
	double b = p_hi;
	double f_a = enthalpy_at(p_masses, p_room_m3, a, p_p_pa) - p_h_total_j;
	double f_b = enthalpy_at(p_masses, p_room_m3, b, p_p_pa) - p_h_total_j;
	double t = a;
	double width = b - a;
	for (int i = 0; i < kSolveIterations; i++) {
		const double denom = f_b - f_a;
		t = std::abs(denom) > 0.0 ? a - f_a * (b - a) / denom : 0.5 * (a + b);
		t = std::min(std::max(t, a), b);
		const double f_t = enthalpy_at(p_masses, p_room_m3, t, p_p_pa) - p_h_total_j;
		if (f_t > 0.0) {
			b = t;
			f_b = f_t;
			f_a *= 0.5;
		} else {
			a = t;
			f_a = f_t;
			f_b *= 0.5;
		}
		if (b - a >= width) {
			break;
		}
		width = b - a;
	}
	return t;
}

// DECISION, not a law: two substances sharing a boundary split the residual by latent capacity. Nothing
// on this planet melts at another substance's melting point.
Dictionary LAMixtureEnthalpy::_pinned(const Dictionary &p_masses, double p_room_m3, double p_t_b,
		double p_p_pa, const Dictionary &p_jump, double p_residual_j) {
	const Dictionary per_id = p_jump["per_id"];
	const double total = double(p_jump["total"]);
	Dictionary share;
	const Array ids = per_id.keys();
	for (int i = 0; i < ids.size(); i++) {
		share[ids[i]] = total > 0.0 ? std::min(std::max(p_residual_j / total, 0.0), 1.0) : 0.0;
	}
	return _report(p_masses, p_room_m3, p_t_b, p_p_pa, share, true);
}

Dictionary LAMixtureEnthalpy::_report(const Dictionary &p_masses, double p_room_m3, double p_t_c,
		double p_p_pa, const Dictionary &p_pinned_share, bool p_pinned) {
	Dictionary melted;
	Dictionary vaporised;
	const Array ids = p_masses.keys();
	for (int i = 0; i < ids.size(); i++) {
		const String id = ids[i];
		const double m = double(p_masses[ids[i]]);
		if (m <= 0.0) {
			continue;
		}
		const double solidus = LASubstances::melt_c_at(id, p_p_pa, 0.0);
		const double liquidus = LASubstances::liquidus_c_at(id, p_p_pa, 0.0);
		double f_m = 1.0;
		if (std::isfinite(solidus)) {
			if (p_t_c <= solidus) {
				f_m = 0.0;
			} else if (p_t_c < liquidus) {
				f_m = (p_t_c - solidus) / (liquidus - solidus);
			}
		}
		const double f_v = vapour_fraction(id, p_t_c, p_p_pa, m, p_room_m3);
		if (p_pinned_share.has(ids[i])) {
			f_m = double(p_pinned_share[ids[i]]);
		}
		melted[ids[i]] = f_m;
		vaporised[ids[i]] = f_v;
	}
	Dictionary out;
	out["t_c"] = p_t_c;
	out["pinned"] = p_pinned;
	out["melted"] = melted;
	out["vaporised"] = vaporised;
	return out;
}

void LAMixtureEnthalpy::_bind_methods() {
	ClassDB::bind_static_method("LAMixtureEnthalpy",
			D_METHOD("vapour_boundary_c", "id", "p_pa"), &vapour_boundary_c);
	ClassDB::bind_static_method("LAMixtureEnthalpy",
			D_METHOD("vapour_p_at", "id", "t_c", "p_pa"), &vapour_p_at);
	ClassDB::bind_static_method("LAMixtureEnthalpy",
			D_METHOD("latent_out_of_condensed", "id", "t_c", "p_pa"), &latent_out_of_condensed);
	ClassDB::bind_static_method("LAMixtureEnthalpy",
			D_METHOD("vapour_fraction", "id", "t_c", "p_pa", "m_kg", "room_m3"), &vapour_fraction);
	ClassDB::bind_static_method("LAMixtureEnthalpy",
			D_METHOD("specific_enthalpy", "id", "t_c", "p_pa", "m_kg", "room_m3"), &specific_enthalpy);
	ClassDB::bind_static_method("LAMixtureEnthalpy",
			D_METHOD("enthalpy_at", "masses", "room_m3", "t_c", "p_pa"), &enthalpy_at);
	ClassDB::bind_static_method("LAMixtureEnthalpy",
			D_METHOD("breakpoints", "masses", "p_pa"), &breakpoints);
	ClassDB::bind_static_method("LAMixtureEnthalpy",
			D_METHOD("jump_at", "masses", "room_m3", "t_b", "p_pa"), &jump_at);
	ClassDB::bind_static_method("LAMixtureEnthalpy",
			D_METHOD("state", "masses", "room_m3", "h_total_j", "p_pa"), &state);
}
