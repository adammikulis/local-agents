#include "LASubstanceRow.hpp"

#include "LAPhaseEos.hpp"
#include "LAPhysicalRead.hpp"
#include "LASubstances.hpp"
#include "LAWaterCurves.hpp"

#include <godot_cpp/templates/hash_map.hpp>
#include <godot_cpp/variant/array.hpp>

#include <cmath>
#include <limits>
#include <memory>
#include <mutex>

using namespace godot;

namespace {

constexpr double kInf = std::numeric_limits<double>::infinity();
constexpr double kPi = 3.14159265358979323846;

double pc(const char *p_name) {
	return la_physical(p_name);
}

LAOpt opt(const Dictionary &p_s, const char *p_key) {
	LAOpt o;
	o.has = p_s.has(p_key);
	o.v = o.has ? double(p_s[p_key]) : 0.0;
	return o;
}

// Specific heat of the dissociated substance, J/kgK: (3/2)R per mole of ATOMS.
double monatomic_c(double p_mm, double p_atoms) {
	if (p_mm <= 0.0 || p_atoms <= 0.0) {
		return 0.0;
	}
	return 1.5 * pc("GAS_CONSTANT_J_MOL_K") * p_atoms / p_mm;
}

// THE LADDER'S ANCHOR: every phase is integrated outward from the row's standard state, where its
// sensible enthalpy is zero (LAPhaseEosFn::anchor). Its energy where the solid starts to melt, J/kg.
double anchor_melt_start(int p_anchor, double p_t_ref, double p_c_sol, double p_c_liq, double p_c_gas,
		double p_melt, double p_boil, double p_l_fus, double p_l_vap) {
	if (p_anchor == 0) {
		return p_c_sol * (p_melt - p_t_ref);
	}
	if (p_anchor == 1) {
		return p_c_liq * (p_melt - p_t_ref) - p_l_fus;
	}
	return p_c_gas * (p_boil - p_t_ref) - p_l_vap - p_c_liq * (p_boil - p_melt) - p_l_fus;
}

// Below the triple pressure: the solid's energy at the frost point, J/kg. A liquid anchor reaches it
// through the triple point.
double anchor_sub_start(int p_anchor, double p_t_ref, double p_c_sol, double p_c_liq, double p_c_gas,
		double p_t_sub, double p_l_sub, double p_t_triple, double p_l_fus) {
	if (p_anchor == 0) {
		return p_c_sol * (p_t_sub - p_t_ref);
	}
	if (p_anchor == 2) {
		return p_c_gas * (p_t_sub - p_t_ref) - p_l_sub;
	}
	return p_c_liq * (p_t_triple - p_t_ref) - p_l_fus - p_c_sol * (p_t_triple - p_t_sub);
}

// ln p = A - B/T, with B fixed by the TWO measured points the table carries -- the triple point and the
// normal boiling point -- so both are reproduced exactly and B * R_v is the MEAN latent heat over the
// interval.
double clapeyron_b_of(const LASubstanceRow &p_r) {
	const double t2_c = p_r.boil_c.or_(kInf);
	if (!std::isfinite(t2_c)) {
		return 0.0;
	}
	const double p2 = p_r.boil_ref_p_pa.or_(pc("STANDARD_PRESSURE_PA"));
	const double t1_c = p_r.triple_t_c.or_(kInf);
	const double p1 = p_r.triple_p_pa.or_(0.0);
	const double KELVIN_OFFSET = pc("KELVIN_OFFSET");
	if (std::isfinite(t1_c) && p1 > 0.0 && p2 > 0.0 && std::abs(t1_c - t2_c) > 0.0) {
		const double inv = 1.0 / (t1_c + KELVIN_OFFSET) - 1.0 / (t2_c + KELVIN_OFFSET);
		if (std::abs(inv) > 0.0) {
			return std::log(p2 / p1) / inv;
		}
	}
	// THIS substance's specific gas constant, R over its molar mass -- not water's.
	const double mm = p_r.molar_mass.or_(0.0);
	if (mm <= 0.0) {
		return 0.0;
	}
	return la_substance::latent_vaporisation_at(p_r, t2_c) * mm / pc("GAS_CONSTANT_J_MOL_K");
}

// Specific enthalpy at a temperature above boiling: sensible heat of the gas, plus the share of the
// atomisation and ionisation energies the equilibrium has actually paid for at that temperature.
double gas_enthalpy_at(const LASubstanceRow &p_r, double p_t_c, double p_p_pa, double p_boil,
		double p_h_boil_end, double p_c_gas) {
	const double t_k = p_t_c + pc("KELVIN_OFFSET");
	const double a_d = la_substance::dissociated_fraction(p_r, t_k, p_p_pa);
	const double a_i = la_substance::ionised_fraction(p_r, t_k, p_p_pa);
	// Once dissociated the carrier is monatomic, so the sensible term crosses over with the fraction.
	const double c_eff = p_c_gas + (p_r.monatomic_c_j_kgk - p_c_gas) * a_d;
	return p_h_boil_end + c_eff * (p_t_c - p_boil) + a_d * p_r.dissociation_j_kg
			+ a_d * a_i * p_r.ionisation_j_kg;
}

// Invert h(T) above the boiling plateau. h rises monotonically with T, so bisection is exact to
// tolerance and needs no starting guess.
double invert_gas_enthalpy(const LASubstanceRow &p_r, double p_h_j_kg, double p_p_pa, double p_boil,
		double p_h_boil_end, double p_c_gas) {
	double lo = p_boil;
	double hi = p_boil + 1.0e5;
	for (int i = 0; i < 60; i++) {
		const double mid = 0.5 * (lo + hi);
		if (gas_enthalpy_at(p_r, mid, p_p_pa, p_boil, p_h_boil_end, p_c_gas) < p_h_j_kg) {
			lo = mid;
		} else {
			hi = mid;
		}
	}
	return 0.5 * (lo + hi);
}

// ABOVE A CONDENSATION PLATEAU the two high transitions are EQUILIBRIA, not plateaus (law of mass action,
// Saha), so enthalpy stays continuous and monotonic and the state is found by inverting it.
Dictionary gas_state(const LASubstanceRow &p_r, double p_h_j_kg, double p_p_pa, double p_ref_t_c,
		double p_h_ref, double p_c_gas, double p_melted) {
	const double t_gas = invert_gas_enthalpy(p_r, p_h_j_kg, p_p_pa, p_ref_t_c, p_h_ref, p_c_gas);
	const double t_k = t_gas + pc("KELVIN_OFFSET");
	const double a_d = la_substance::dissociated_fraction(p_r, t_k, p_p_pa);
	const double a_i = la_substance::ionised_fraction(p_r, t_k, p_p_pa);
	int ph = LASubstances::GAS;
	const double p_crit = p_r.critical_p_pa.or_(kInf);
	const double t_crit = p_r.critical_t_c.or_(kInf);
	if (std::isfinite(p_crit) && p_p_pa >= p_crit && t_gas >= t_crit) {
		ph = LASubstances::SUPERCRITICAL;
	}
	if (a_i >= 0.5) {
		ph = LASubstances::PLASMA;
	} else if (a_d >= 0.5) {
		ph = LASubstances::ATOMS;
	}
	Dictionary out;
	out["t_c"] = t_gas;
	out["phase"] = ph;
	out["melted"] = p_melted;
	out["vaporised"] = 1.0;
	out["dissociated"] = a_d;
	out["ionised"] = a_i;
	return out;
}

void fill_formula(LASubstanceRow &p_r, const Dictionary &p_s) {
	const Dictionary f = Dictionary(p_s.get("formula", Dictionary()));
	p_r.formula_empty = f.is_empty();
	const Array keys = f.keys();
	const Dictionary entropy = LASubstances::element_entropy_j_molk();
	const Dictionary ev = LASubstances::element_ionisation_ev();
	const Dictionary dg = LASubstances::element_degen();
	const double ev_to_j_mol = pc("EV_TO_J_PER_MOL");
	const double avogadro = pc("AVOGADRO_PER_MOL");
	const double mm = p_r.molar_mass.or_(0.0);
	double atoms = 0.0;
	double nu = 0.0;
	double s_atoms = 0.0;
	bool measured = true;
	double ion_j_mol = 0.0;
	bool ion_all = true;
	for (int i = 0; i < keys.size(); i++) {
		const double n = double(f[keys[i]]);
		atoms += n;
		if (measured && !entropy.has(keys[i])) {
			measured = false;
		}
		if (measured) {
			nu += n;
			s_atoms += n * double(entropy[keys[i]]);
		}
		if (ion_all && !ev.has(keys[i])) {
			ion_all = false;
		}
		if (ion_all) {
			ion_j_mol += double(f[keys[i]]) * double(ev[keys[i]]) * ev_to_j_mol;
		}
		if (!ev.has(keys[i]) || !dg.has(keys[i])) {
			continue;
		}
		const double chi = double(ev[keys[i]]) * ev_to_j_mol / avogadro;
		const Array g = dg[keys[i]];
		const double g0 = double(g[0]) > 1.0 ? double(g[0]) : 1.0;
		p_r.ions.push_back({ n, chi, 2.0 * double(g[1]) / g0 });
	}
	p_r.atoms = atoms;
	p_r.dissociates = measured && nu > 1.0;
	p_r.nu = nu;
	p_r.s_atoms = s_atoms;
	p_r.monatomic_c_j_kgk = monatomic_c(mm, atoms);
	p_r.ionisation_j_kg = (p_r.formula_empty || mm <= 0.0 || !ion_all) ? 0.0 : ion_j_mol / mm;
}

void fill(LASubstanceRow &p_r, const String &p_id, const Dictionary &p_s) {
	p_r.id = p_id;
	p_r.iapws = bool(p_s.get("iapws", false));
	p_r.molar_mass = opt(p_s, "molar_mass");
	p_r.specific_heat = opt(p_s, "specific_heat");
	p_r.specific_heat_solid = opt(p_s, "specific_heat_solid");
	p_r.specific_heat_gas = opt(p_s, "specific_heat_gas");
	p_r.melt_c = opt(p_s, "melt_c");
	p_r.triple_t_c = opt(p_s, "triple_t_c");
	p_r.triple_p_pa = opt(p_s, "triple_p_pa");
	p_r.boil_c = opt(p_s, "boil_c");
	p_r.boil_ref_p_pa = opt(p_s, "boil_ref_p_pa");
	p_r.critical_t_c = opt(p_s, "critical_t_c");
	p_r.critical_p_pa = opt(p_s, "critical_p_pa");
	p_r.latent_fusion_j_kg = opt(p_s, "latent_fusion_j_kg");
	p_r.latent_vaporisation_j_kg = opt(p_s, "latent_vaporisation_j_kg");
	p_r.latent_vaporisation_ref_t_c = opt(p_s, "latent_vaporisation_ref_t_c");
	p_r.atomisation_j_mol = opt(p_s, "atomisation_j_mol");
	p_r.entropy_gas_j_molk = opt(p_s, "entropy_gas_j_molk");
	const double mm = p_r.molar_mass.or_(0.0);
	p_r.r_specific = mm > 0.0 ? pc("GAS_CONSTANT_J_MOL_K") / mm : 0.0;
	const double j_mol = p_r.atomisation_j_mol.or_(0.0);
	p_r.dissociation_j_kg = (j_mol > 0.0 && mm > 0.0) ? j_mol / mm : 0.0;
	fill_formula(p_r, p_s);
	p_r.clapeyron_b = clapeyron_b_of(p_r);
}

struct Rows {
	std::vector<std::unique_ptr<LASubstanceRow>> held;
	HashMap<String, const LASubstanceRow *> by_id;

	const LASubstanceRow &add(const String &p_id, const Dictionary &p_s) {
		held.push_back(std::make_unique<LASubstanceRow>());
		fill(*held.back(), p_id, p_s);
		by_id.insert(p_id, held.back().get());
		return *held.back();
	}
};

// The rows of the finished table. Only read once the table is whole: a row built off a partial table would
// be missing what is added after it.
const Rows &rows() {
	static const Rows *built = []() {
		Rows *out = new Rows();
		const Dictionary table = LASubstances::table();
		const Array ids = table.keys();
		for (int i = 0; i < ids.size(); i++) {
			out->add(String(ids[i]), Dictionary(table[ids[i]]));
		}
		return out;
	}();
	return *built;
}

// The rows asked for while the table is still being built, and the ones it never names; each answers
// with whatever the table holds of it at that moment and defaults for the rest.
const LASubstanceRow &unlisted(const String &p_id) {
	static std::mutex lock;
	static Rows *held = new Rows();
	std::lock_guard<std::mutex> guard(lock);
	const LASubstanceRow *const *at = held->by_id.getptr(p_id);
	if (at != nullptr) {
		return **at;
	}
	return held->add(p_id, Dictionary(LASubstances::table().get(p_id, Dictionary())));
}

} // namespace

const LACondensedEos &LASubstanceRow::condensed() const {
	const LACondensedEos *p = condensed_rule.load(std::memory_order_acquire);
	if (p == nullptr) {
		p = &LAPhaseEosFn::condensed(id);
		condensed_rule.store(p, std::memory_order_release);
	}
	return *p;
}

const LAFluidEos &LASubstanceRow::fluid() const {
	const LAFluidEos *p = fluid_rule.load(std::memory_order_acquire);
	if (p == nullptr) {
		p = &LAPhaseEosFn::fluid(id);
		fluid_rule.store(p, std::memory_order_release);
	}
	return *p;
}

const LAAnchor &LASubstanceRow::anchor() const {
	const LAAnchor *p = anchor_rule.load(std::memory_order_acquire);
	if (p == nullptr) {
		p = &LAPhaseEosFn::anchor(id);
		anchor_rule.store(p, std::memory_order_release);
	}
	return *p;
}

const LASubstanceRow &la_substance::row(const String &p_id) {
	if (!LASubstances::table_ready()) {
		return unlisted(p_id);
	}
	const LASubstanceRow *const *at = rows().by_id.getptr(p_id);
	return at != nullptr ? **at : unlisted(p_id);
}

double la_substance::latent_vaporisation_at(const LASubstanceRow &p_r, double p_t_c) {
	const double l_ref = p_r.latent_vaporisation_j_kg.or_(0.0);
	if (l_ref <= 0.0) {
		return 0.0;
	}
	const double t_crit = p_r.critical_t_c.or_(kInf);
	if (!std::isfinite(t_crit)) {
		return l_ref;
	}
	if (p_t_c >= t_crit) {
		return 0.0;
	}
	const double t_ref = p_r.latent_vaporisation_ref_t_c.or_(0.0);
	const double span_ref = t_crit - t_ref;
	if (span_ref <= 0.0) {
		return l_ref;
	}
	return l_ref * std::pow((t_crit - p_t_c) / span_ref, pc("WATSON_LATENT_EXPONENT"));
}

// Latent heat of sublimation, J/kg -- DERIVED as fusion + vaporisation so Hess's law cannot be violated.
double la_substance::latent_sublimation_j_kg(const LASubstanceRow &p_r) {
	return p_r.latent_fusion_j_kg.or_(0.0) + p_r.latent_vaporisation_j_kg.or_(0.0);
}

// THE BOILING POINT AT A GIVEN PRESSURE -- the boundary curve solved for temperature.
double la_substance::boil_c_at(const LASubstanceRow &p_r, double p_p_pa) {
	if (p_r.iapws) {
		return la_water::iapws_saturation_t_k(p_p_pa) - pc("KELVIN_OFFSET");
	}
	const double t_ref_c = p_r.boil_c.or_(kInf);
	if (!std::isfinite(t_ref_c)) {
		return kInf;
	}
	const double p_ref = p_r.boil_ref_p_pa.or_(pc("STANDARD_PRESSURE_PA"));
	const double p_crit = p_r.critical_p_pa.or_(kInf);
	const double t_crit = p_r.critical_t_c.or_(kInf);
	if (std::isfinite(p_crit) && p_p_pa >= p_crit) {
		return t_crit;
	}
	const double KELVIN_OFFSET = pc("KELVIN_OFFSET");
	const double p = p_p_pa > 1.0 ? p_p_pa : 1.0;
	const double t_ref_k = t_ref_c + KELVIN_OFFSET;
	const double b = p_r.clapeyron_b;
	if (b <= 0.0) {
		return t_ref_c;
	}
	const double inv_t = 1.0 / t_ref_k - std::log(p / p_ref) / b;
	// Past the curve's own limit no temperature boils it: condensed at every T.
	if (inv_t <= 0.0) {
		return kInf;
	}
	const double t_c = 1.0 / inv_t - KELVIN_OFFSET;
	// The boundary cannot run past the critical point; beyond it the two phases are one.
	return std::isfinite(t_crit) ? (t_c < t_crit ? t_c : t_crit) : t_c;
}

// Melting point at pressure, and depressed by dissolved solute: the one rule's solidus, whose Clapeyron
// slope takes both phases at the melting point.
double la_substance::melt_c_at(const LASubstanceRow &p_r, double p_p_pa, double p_molality_mol_kg) {
	double t_c = LAPhaseEosFn::solidus_c(p_r.condensed(), p_p_pa);
	if (!std::isfinite(t_c)) {
		return kInf;
	}
	// van 't Hoff, about the PURE solvent's melting point at this pressure: K_f = R T_m^2 / L_fus.
	const double l_fus = p_r.latent_fusion_j_kg.or_(0.0);
	if (p_molality_mol_kg > 0.0 && l_fus > 0.0) {
		const double t_m_k = t_c + pc("KELVIN_OFFSET");
		t_c -= pc("GAS_CONSTANT_J_MOL_K") * t_m_k * t_m_k / l_fus * p_molality_mol_kg;
	}
	return t_c;
}

// THE LIQUIDUS AT PRESSURE -- the temperature the last crystal goes. Water is the degenerate case where
// it meets the solidus. DECISION, not a law: the interval keeps its width, both ends on one Clapeyron
// slope.
double la_substance::liquidus_c_at(const LASubstanceRow &p_r, double p_p_pa, double p_molality_mol_kg) {
	const double solidus = melt_c_at(p_r, p_p_pa, p_molality_mol_kg);
	return std::isfinite(solidus) ? solidus + p_r.condensed().width : kInf;
}

// THE LIQUID-VAPOUR BOUNDARY READ AS A PRESSURE -- boil_c_at() inverted, so one curve answers from
// either end and the plateau's temperature cannot disagree with the latent heat charged to cross it.
double la_substance::saturation_p_at(const LASubstanceRow &p_r, double p_t_c) {
	if (p_r.iapws) {
		return la_water::iapws_saturation_p_pa(p_t_c + pc("KELVIN_OFFSET"));
	}
	const double t_ref_c = p_r.boil_c.or_(kInf);
	if (!std::isfinite(t_ref_c)) {
		return 0.0;
	}
	const double b = p_r.clapeyron_b;
	if (b <= 0.0) {
		return 0.0;
	}
	const double t_crit = p_r.critical_t_c.or_(kInf);
	if (std::isfinite(t_crit) && p_t_c >= t_crit) {
		return p_r.critical_p_pa.or_(0.0);
	}
	const double KELVIN_OFFSET = pc("KELVIN_OFFSET");
	const double p_ref = p_r.boil_ref_p_pa.or_(pc("STANDARD_PRESSURE_PA"));
	const double t_k_raw = p_t_c + KELVIN_OFFSET;
	const double t_k = t_k_raw > 1.0 ? t_k_raw : 1.0;
	const double t_ref_k = t_ref_c + KELVIN_OFFSET;
	return p_ref * std::exp(-b * (1.0 / t_k - 1.0 / t_ref_k));
}

// Sublimation pressure at temperature -- the solid-vapour boundary, Clausius-Clapeyron anchored on the
// triple point with the SUBLIMATION enthalpy (fusion + vaporisation, derived, so Hess still closes).
double la_substance::sublimation_p_at(const LASubstanceRow &p_r, double p_t_c) {
	if (p_r.iapws) {
		return la_water::iapws_sublimation_p_pa(p_t_c + pc("KELVIN_OFFSET"));
	}
	const double t3 = p_r.triple_t_c.or_(kInf);
	const double p3 = p_r.triple_p_pa.or_(0.0);
	if (!std::isfinite(t3) || p3 <= 0.0) {
		return 0.0;
	}
	const double l_sub = latent_sublimation_j_kg(p_r);
	const double r_v = p_r.r_specific;
	if (l_sub <= 0.0 || r_v <= 0.0) {
		return 0.0;
	}
	const double KELVIN_OFFSET = pc("KELVIN_OFFSET");
	const double t3_k = t3 + KELVIN_OFFSET;
	const double t_k_raw = p_t_c + KELVIN_OFFSET;
	const double t_k = t_k_raw > 1.0 ? t_k_raw : 1.0;
	return p3 * std::exp(-(l_sub / r_v) * (1.0 / t_k - 1.0 / t3_k));
}

// THE FROST POINT AT A GIVEN PRESSURE, C -- sublimation_p_at() inverted, so the solid-vapour boundary is
// one curve read from either end.
double la_substance::sublimation_c_at(const LASubstanceRow &p_r, double p_p_pa) {
	if (p_r.iapws) {
		return la_water::iapws_sublimation_t_k(p_p_pa) - pc("KELVIN_OFFSET");
	}
	const double t3 = p_r.triple_t_c.or_(kInf);
	const double p3 = p_r.triple_p_pa.or_(0.0);
	if (!std::isfinite(t3) || p3 <= 0.0) {
		return kInf;
	}
	const double l_sub = latent_sublimation_j_kg(p_r);
	const double r_v = p_r.r_specific;
	if (l_sub <= 0.0 || r_v <= 0.0) {
		return t3;
	}
	const double KELVIN_OFFSET = pc("KELVIN_OFFSET");
	const double p = p_p_pa > 1.0e-12 ? p_p_pa : 1.0e-12;
	const double inv_t = 1.0 / (t3 + KELVIN_OFFSET) - (r_v / l_sub) * std::log(p / p3);
	if (inv_t <= 0.0) {
		return t3;
	}
	return 1.0 / inv_t - KELVIN_OFFSET;
}

// True when this substance has NO liquid phase at this pressure: below the triple-point pressure a solid
// goes straight to vapour.
bool la_substance::sublimes_at(const LASubstanceRow &p_r, double p_p_pa) {
	const double p3 = p_r.triple_p_pa.or_(0.0);
	return p3 > 0.0 && p_p_pa < p3;
}

// Dissociated fraction at temperature and pressure, from the law of mass action. M <-> v atoms, with
// dG = dH_atomisation - T dS and dS the free atoms' standard entropies minus the molecule's.
double la_substance::dissociated_fraction(const LASubstanceRow &p_r, double p_t_k, double p_p_pa) {
	const double dh = p_r.atomisation_j_mol.or_(0.0);
	const double s_mol = p_r.entropy_gas_j_molk.or_(0.0);
	if (dh <= 0.0 || s_mol <= 0.0 || p_t_k <= 0.0) {
		return 0.0;
	}
	if (!p_r.dissociates) {
		return 0.0;
	}
	const double nu = p_r.nu;
	const double s_atoms = p_r.s_atoms;
	const double dg = dh - p_t_k * (s_atoms - s_mol);
	const double ln_k = -dg / (pc("GAS_CONSTANT_J_MOL_K") * p_t_k);
	// Bisect on the extent. K_p(alpha) is monotonic increasing, so a bracket search is exact to tolerance.
	const double pr = (p_p_pa > 1.0 ? p_p_pa : 1.0) / pc("STANDARD_PRESSURE_PA");
	double lo = 0.0;
	double hi = 1.0;
	for (int i = 0; i < 48; i++) {
		const double a = 0.5 * (lo + hi);
		const double tot = 1.0 + (nu - 1.0) * a;
		const double x_a = nu * a / tot;
		const double x_m = (1.0 - a) / tot;
		double lhs = -1.0e30;
		if (x_m > 1.0e-30 && x_a > 1.0e-30) {
			lhs = nu * std::log(x_a) - std::log(x_m) + (nu - 1.0) * std::log(pr);
		}
		if (lhs < ln_k) {
			lo = a;
		} else {
			hi = a;
		}
	}
	return 0.5 * (lo + hi);
}

// Ionised fraction from the SAHA equation, per element and mole-weighted. Single stage: the closed-form
// root of x^2/(1-x) = S.
double la_substance::ionised_fraction(const LASubstanceRow &p_r, double p_t_k, double p_p_pa) {
	if (p_r.formula_empty || p_t_k <= 0.0) {
		return 0.0;
	}
	const double boltzmann = pc("BOLTZMANN_J_K");
	const double planck = pc("PLANCK_J_S");
	const double n_m3 = (p_p_pa > 1.0 ? p_p_pa : 1.0) / (boltzmann * p_t_k);
	const double kt = boltzmann * p_t_k;
	// The thermal de Broglie factor, (2 pi m_e k T / h^2)^(3/2).
	const double lam = std::pow(2.0 * kPi * pc("ELECTRON_MASS_KG") * kt / (planck * planck), 1.5);
	double ion_atoms = 0.0;
	for (const LASubstanceRow::Ion &ion : p_r.ions) {
		const double big = ion.ratio * lam * std::exp(-ion.chi_j / kt) / (n_m3 > 1.0 ? n_m3 : 1.0);
		double x = 0.0;
		if (big > 0.0) {
			x = 0.5 * (-big + std::sqrt(big * big + 4.0 * big));
		}
		ion_atoms += ion.n * (x < 0.0 ? 0.0 : (x > 1.0 ? 1.0 : x));
	}
	return p_r.atoms > 0.0 ? ion_atoms / p_r.atoms : 0.0;
}

// SPECIFIC ENTHALPY (J/kg) at a temperature, referenced to the solid at 0 K. The inverse of
// enthalpy_to_state(), rung for rung; on a ZERO-WIDTH plateau it returns the LOWER end.
double la_substance::enthalpy_at(const LASubstanceRow &p_r, double p_t_c, double p_p_pa,
		double p_molality_mol_kg) {
	const double c_liq = p_r.specific_heat.or_(NAN);
	const double c_sol = p_r.specific_heat_solid.or_(NAN);
	const double c_gas = p_r.specific_heat_gas.or_(NAN);
	const double KELVIN_OFFSET = pc("KELVIN_OFFSET");
	const LAAnchor &anc = p_r.anchor();
	const int anchor = anc.phase;
	const double t_ref = anc.t_c;
	const double t_triple = p_r.triple_t_c.or_(NAN);
	// Pressure-dependent, and depressed by any dissolved solute. For water the Clapeyron slope is negative.
	const double melt_row = melt_c_at(p_r, p_p_pa, p_molality_mol_kg);
	const bool has_melt = std::isfinite(melt_row);
	const double boil = boil_c_at(p_r, p_p_pa);
	if (!has_melt && !std::isfinite(boil)) {
		// Never melts on this planet: the solid's sensible heat from the standard state.
		return c_sol * (p_t_c - t_ref);
	}
	// A row with no solid is liquid from absolute zero: its fusion rung stands at 0 K and costs nothing.
	const double melt = has_melt ? melt_row : -KELVIN_OFFSET;
	const double l_fus = has_melt ? p_r.latent_fusion_j_kg.v : 0.0;

	// NO LIQUID BELOW THE TRIPLE POINT. The plateau crossed is SUBLIMATION at the frost point.
	if (sublimes_at(p_r, p_p_pa)) {
		const double t_sub = sublimation_c_at(p_r, p_p_pa);
		const double l_sub = latent_sublimation_j_kg(p_r);
		const double h_sub_start = anchor_sub_start(anchor, t_ref, c_sol, c_liq, c_gas, t_sub, l_sub, t_triple, l_fus);
		if (p_t_c <= t_sub) {
			return p_t_c == t_sub ? h_sub_start : h_sub_start - c_sol * (t_sub - p_t_c);
		}
		return gas_enthalpy_at(p_r, p_t_c, p_p_pa, t_sub, h_sub_start + l_sub, c_gas);
	}

	// The liquidus is the solidus this call has just read, plus the interval's width.
	const double liquidus = has_melt ? melt_row + p_r.condensed().width : -KELVIN_OFFSET;
	const double l_vap = std::isfinite(boil) ? latent_vaporisation_at(p_r, boil) : 0.0;
	const double h_start = anchor_melt_start(anchor, t_ref, c_sol, c_liq, c_gas, melt, boil, l_fus, l_vap);
	if (p_t_c <= melt) {
		return p_t_c == melt ? h_start : h_start - c_sol * (melt - p_t_c);
	}
	const double h_end = h_start + l_fus + c_liq * (liquidus - melt);
	if (p_t_c < liquidus) {
		// Lever rule across the mush: solid and liquid enthalpies weighted by the melt fraction.
		const double x = p_t_c - melt;
		const double phi = x / (liquidus - melt);
		return h_start + c_sol * x + phi * (l_fus + (c_liq - c_sol) * x);
	}
	if (!std::isfinite(boil) || p_t_c <= boil) {
		return h_end + c_liq * (p_t_c - liquidus);
	}
	// THE LATENT HEAT AT THE BOUNDARY, not the table's reference value: the plateau is zero at the
	// critical point. Above it the atomisation and ionisation energies are paid by equilibrium.
	const double h_top = h_end + c_liq * (boil - liquidus) + l_vap;
	return gas_enthalpy_at(p_r, p_t_c, p_p_pa, boil, h_top, c_gas);
}

Dictionary la_substance::enthalpy_to_state(const LASubstanceRow &p_r, double p_h_j_kg, double p_p_pa,
		double p_molality_mol_kg) {
	const double c_liq = p_r.specific_heat.or_(NAN);
	const double c_sol = p_r.specific_heat_solid.or_(NAN);
	const double c_gas = p_r.specific_heat_gas.or_(NAN);
	const double KELVIN_OFFSET = pc("KELVIN_OFFSET");
	const LAAnchor &anc = p_r.anchor();
	const int anchor = anc.phase;
	const double t_ref = anc.t_c;
	const double t_triple = p_r.triple_t_c.or_(NAN);
	// Pressure-dependent, and depressed by dissolved solute. For water the Clapeyron slope is negative.
	const double melt_row = melt_c_at(p_r, p_p_pa, p_molality_mol_kg);
	const bool has_melt = std::isfinite(melt_row);
	// A row with no solid is liquid from absolute zero: its fusion rung stands at 0 K and costs nothing.
	const double melt = has_melt ? melt_row : -KELVIN_OFFSET;
	const double liquidus = has_melt ? liquidus_c_at(p_r, p_p_pa, p_molality_mol_kg) : -KELVIN_OFFSET;
	// THE BOUNDARY AT THIS PRESSURE, not the one-atmosphere reference point. See boil_c_at().
	const double boil = boil_c_at(p_r, p_p_pa);
	const double l_fus = has_melt ? p_r.latent_fusion_j_kg.v : 0.0;
	// THE LATENT HEAT AT THE BOUNDARY: at high pressure the plateau gets SHORTER, reaching zero at the
	// critical point, which is why a supercritical cell has no plateau at all below.
	const double l_vap = std::isfinite(boil) ? latent_vaporisation_at(p_r, boil) : 0.0;

	Dictionary out;
	if (!has_melt && !std::isfinite(boil)) {
		// A substance this planet never melts. Temperature is sensible heat from the standard state.
		out["t_c"] = t_ref + p_h_j_kg / c_sol;
		out["phase"] = int(LASubstances::SOLID);
		out["melted"] = 0.0;
		out["vaporised"] = 0.0;
		return out;
	}

	// NO LIQUID BELOW THE TRIPLE POINT. The plateau crossed is SUBLIMATION at the frost point, not
	// fusion, and the next ramp is the gas.
	if (sublimes_at(p_r, p_p_pa)) {
		const double t_sub = sublimation_c_at(p_r, p_p_pa);
		const double l_sub = latent_sublimation_j_kg(p_r);
		const double h_sub_start = anchor_sub_start(anchor, t_ref, c_sol, c_liq, c_gas, t_sub, l_sub, t_triple, l_fus);
		if (p_h_j_kg <= h_sub_start) {
			out["t_c"] = t_sub - (h_sub_start - p_h_j_kg) / c_sol;
			out["phase"] = int(LASubstances::SOLID);
			out["melted"] = 0.0;
			out["vaporised"] = 0.0;
			out["sublimating"] = true;
			out["dissociated"] = 0.0;
			out["ionised"] = 0.0;
			return out;
		}
		const double h_sub_end = h_sub_start + l_sub;
		if (p_h_j_kg < h_sub_end) {
			out["t_c"] = t_sub;
			out["phase"] = int(LASubstances::SOLID);
			out["melted"] = 0.0;
			out["vaporised"] = l_sub > 0.0 ? (p_h_j_kg - h_sub_start) / l_sub : 1.0;
			out["sublimating"] = true;
			out["dissociated"] = 0.0;
			out["ionised"] = 0.0;
			return out;
		}
		Dictionary st = gas_state(p_r, p_h_j_kg, p_p_pa, t_sub, h_sub_end, c_gas, 0.0);
		st["sublimating"] = true;
		return st;
	}

	const double h_melt_start = anchor_melt_start(anchor, t_ref, c_sol, c_liq, c_gas, melt, boil, l_fus, l_vap);
	if (p_h_j_kg <= h_melt_start) {
		out["t_c"] = melt - (h_melt_start - p_h_j_kg) / c_sol;
		out["phase"] = int(LASubstances::SOLID);
		out["melted"] = 0.0;
		out["vaporised"] = 0.0;
		return out;
	}

	const double h_melt_end = h_melt_start + l_fus + c_liq * (liquidus - melt);
	if (p_h_j_kg < h_melt_end) {
		// IN THE MUSH: temperature RISES through the melting interval as the crystals go. The quadratic
		// is the lever rule solved for the melt fraction; a zero-width interval pins the temperature.
		const double dh = p_h_j_kg - h_melt_start;
		const double dt = liquidus - melt;
		const double a2 = (c_liq - c_sol) * dt;
		const double a1 = c_sol * dt + l_fus;
		const double phi = dt > 0.0 ? 2.0 * dh / (a1 + std::sqrt(a1 * a1 + 4.0 * a2 * dh)) : dh / l_fus;
		out["t_c"] = melt + phi * dt;
		out["phase"] = int(LASubstances::SOLID);
		out["melted"] = phi;
		out["vaporised"] = 0.0;
		return out;
	}

	if (!std::isfinite(boil)) {
		out["t_c"] = liquidus + (p_h_j_kg - h_melt_end) / c_liq;
		out["phase"] = int(LASubstances::LIQUID);
		out["melted"] = 1.0;
		out["vaporised"] = 0.0;
		return out;
	}

	const double h_boil_start = h_melt_end + c_liq * (boil - liquidus);
	if (p_h_j_kg <= h_boil_start) {
		out["t_c"] = liquidus + (p_h_j_kg - h_melt_end) / c_liq;
		out["phase"] = int(LASubstances::LIQUID);
		out["melted"] = 1.0;
		out["vaporised"] = 0.0;
		return out;
	}

	const double h_boil_end = h_boil_start + l_vap;
	if (p_h_j_kg < h_boil_end) {
		out["t_c"] = boil;
		out["phase"] = int(LASubstances::LIQUID);
		out["melted"] = 1.0;
		out["vaporised"] = l_vap > 0.0 ? (p_h_j_kg - h_boil_start) / l_vap : 1.0;
		return out;
	}

	return gas_state(p_r, p_h_j_kg, p_p_pa, boil, h_boil_end, c_gas, 1.0);
}
