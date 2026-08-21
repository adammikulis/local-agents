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

// THE SATURATION SPLIT, by Dalton at the cell's TOTAL pressure: n_v / n_gas = p_v / (p - p_v). When p_v
// reaches p there is no room for anything else and the condensate is gone -- that is what boiling IS.
double LAMixtureEnthalpy::vapour_fraction(const String &p_id, double p_t_c, double p_p_pa, double p_m_kg,
		double p_n_gas_mol) {
	if (p_m_kg <= 0.0 || p_p_pa <= 0.0) {
		return 0.0;
	}
	const double vap_t = vapour_boundary_c(p_id, p_p_pa);
	if (!std::isfinite(vap_t)) {
		return 0.0;
	}
	// STRICTLY above: at the boundary itself the Dalton form decides, so the value stays the LOWER end
	// of any jump there -- the convention the boundary walk counts on.
	if (p_t_c > vap_t) {
		return 1.0;
	}
	if (p_n_gas_mol <= 0.0) {
		return 0.0;
	}
	const double p_v = vapour_p_at(p_id, p_t_c, p_p_pa);
	if (p_v <= 0.0) {
		return 0.0;
	}
	if (p_v >= p_p_pa) {
		return 1.0;
	}
	const double mm = prop(p_id, "molar_mass", 0.0);
	if (mm <= 0.0) {
		return 0.0;
	}
	return std::min(p_n_gas_mol * p_v / (p_p_pa - p_v) * mm / p_m_kg, 1.0);
}

// Specific enthalpy of one substance AS IT SITS IN THIS CELL: its own curve plus the latent heat of the
// share held as vapour. Above the vapour boundary the curve already carries it.
double LAMixtureEnthalpy::specific_enthalpy(const String &p_id, double p_t_c, double p_p_pa, double p_m_kg,
		double p_n_gas_mol) {
	const double h = LASubstances::enthalpy_at(p_id, p_t_c, p_p_pa, 0.0);
	const double vap_t = vapour_boundary_c(p_id, p_p_pa);
	if (!std::isfinite(vap_t) || p_t_c > vap_t) {
		return h;
	}
	const double f_v = vapour_fraction(p_id, p_t_c, p_p_pa, p_m_kg, p_n_gas_mol);
	if (f_v <= 0.0) {
		return h;
	}
	return h + f_v * latent_out_of_condensed(p_id, p_t_c, p_p_pa);
}

// Total enthalpy of the cell at a temperature, J.
double LAMixtureEnthalpy::enthalpy_at(const Dictionary &p_masses, double p_n_gas_mol, double p_t_c,
		double p_p_pa) {
	double h = 0.0;
	const Array ids = p_masses.keys();
	for (int i = 0; i < ids.size(); i++) {
		const String id = ids[i];
		const double m = double(p_masses[ids[i]]);
		if (m > 0.0) {
			h += m * specific_enthalpy(id, p_t_c, p_p_pa, m, p_n_gas_mol);
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

// The height of the discontinuity at a boundary, J: the latent heat of whatever is still CONDENSED there.
// The boiling step vanishes when non-condensable gas is present -- the vapour share reaches one smoothly.
Dictionary LAMixtureEnthalpy::jump_at(const Dictionary &p_masses, double p_n_gas_mol, double p_t_b,
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
			j += m * (1.0 - vapour_fraction(id, p_t_b, p_p_pa, m, p_n_gas_mol)) * l_fus;
		}
		const double vap_t = vapour_boundary_c(id, p_p_pa);
		if (std::isfinite(vap_t) && Math::is_equal_approx(vap_t, p_t_b) && p_n_gas_mol <= 0.0) {
			j += m * latent_out_of_condensed(id, p_t_b, p_p_pa);
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
Dictionary LAMixtureEnthalpy::state(const Dictionary &p_masses, double p_n_gas_mol, double p_h_total_j,
		double p_p_pa) {
	double lo = -la_physical("KELVIN_OFFSET");
	double h_lo = enthalpy_at(p_masses, p_n_gas_mol, lo, p_p_pa);
	if (p_h_total_j <= h_lo) {
		return _report(p_masses, p_n_gas_mol, lo, p_p_pa, Dictionary(), false);
	}
	double hi = kInf;
	const PackedFloat64Array bps = breakpoints(p_masses, p_p_pa);
	for (int i = 0; i < bps.size(); i++) {
		const double t_b = bps[i];
		if (t_b <= lo) {
			continue;
		}
		const double h_b = enthalpy_at(p_masses, p_n_gas_mol, t_b, p_p_pa);
		if (p_h_total_j <= h_b) {
			hi = t_b;
			break;
		}
		const Dictionary jump = jump_at(p_masses, p_n_gas_mol, t_b, p_p_pa);
		const double top = h_b + double(jump["total"]);
		if (p_h_total_j < top) {
			return _pinned(p_masses, p_n_gas_mol, t_b, p_p_pa, jump, p_h_total_j - h_b);
		}
		lo = t_b;
		h_lo = top;
	}
	if (!std::isfinite(hi)) {
		// Past the last boundary the curve only rises, so doubling the span always finds the far end.
		double span = kBracketSpanC;
		for (int i = 0; i < kBracketDoublings; i++) {
			hi = lo + span;
			if (enthalpy_at(p_masses, p_n_gas_mol, hi, p_p_pa) >= p_h_total_j) {
				break;
			}
			span *= 2.0;
		}
	}
	return _report(p_masses, p_n_gas_mol,
			_solve(p_masses, p_n_gas_mol, p_h_total_j, p_p_pa, lo, hi), p_p_pa, Dictionary(), false);
}

// Illinois false position over a bracket the boundary walk already proved. Exact in one step on a linear
// segment; the halving keeps an end from sticking where the saturation split makes it curve.
double LAMixtureEnthalpy::_solve(const Dictionary &p_masses, double p_n_gas_mol, double p_h_total_j,
		double p_p_pa, double p_lo, double p_hi) {
	double a = p_lo;
	double b = p_hi;
	double f_a = enthalpy_at(p_masses, p_n_gas_mol, a, p_p_pa) - p_h_total_j;
	double f_b = enthalpy_at(p_masses, p_n_gas_mol, b, p_p_pa) - p_h_total_j;
	double t = a;
	double width = b - a;
	for (int i = 0; i < kSolveIterations; i++) {
		const double denom = f_b - f_a;
		t = std::abs(denom) > 0.0 ? a - f_a * (b - a) / denom : 0.5 * (a + b);
		t = std::min(std::max(t, a), b);
		const double f_t = enthalpy_at(p_masses, p_n_gas_mol, t, p_p_pa) - p_h_total_j;
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
Dictionary LAMixtureEnthalpy::_pinned(const Dictionary &p_masses, double p_n_gas_mol, double p_t_b,
		double p_p_pa, const Dictionary &p_jump, double p_residual_j) {
	const Dictionary per_id = p_jump["per_id"];
	const double total = double(p_jump["total"]);
	Dictionary share;
	const Array ids = per_id.keys();
	for (int i = 0; i < ids.size(); i++) {
		share[ids[i]] = total > 0.0 ? std::min(std::max(p_residual_j / total, 0.0), 1.0) : 0.0;
	}
	return _report(p_masses, p_n_gas_mol, p_t_b, p_p_pa, share, true);
}

Dictionary LAMixtureEnthalpy::_report(const Dictionary &p_masses, double p_n_gas_mol, double p_t_c,
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
		double f_v = vapour_fraction(id, p_t_c, p_p_pa, m, p_n_gas_mol);
		if (p_pinned_share.has(ids[i])) {
			const double vap_t = vapour_boundary_c(id, p_p_pa);
			if (std::isfinite(vap_t) && Math::is_equal_approx(vap_t, p_t_c)) {
				f_v = double(p_pinned_share[ids[i]]);
			} else {
				f_m = double(p_pinned_share[ids[i]]);
			}
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
			D_METHOD("vapour_fraction", "id", "t_c", "p_pa", "m_kg", "n_gas_mol"), &vapour_fraction);
	ClassDB::bind_static_method("LAMixtureEnthalpy",
			D_METHOD("specific_enthalpy", "id", "t_c", "p_pa", "m_kg", "n_gas_mol"), &specific_enthalpy);
	ClassDB::bind_static_method("LAMixtureEnthalpy",
			D_METHOD("enthalpy_at", "masses", "n_gas_mol", "t_c", "p_pa"), &enthalpy_at);
	ClassDB::bind_static_method("LAMixtureEnthalpy",
			D_METHOD("breakpoints", "masses", "p_pa"), &breakpoints);
	ClassDB::bind_static_method("LAMixtureEnthalpy",
			D_METHOD("jump_at", "masses", "n_gas_mol", "t_b", "p_pa"), &jump_at);
	ClassDB::bind_static_method("LAMixtureEnthalpy",
			D_METHOD("state", "masses", "n_gas_mol", "h_total_j", "p_pa"), &state);
}
