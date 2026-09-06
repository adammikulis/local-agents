#include "LAColumnRadiation.hpp"

#include "LAAbsorptionBands.hpp"
#include "LAPhysicalRead.hpp"
#include "LASubstances.hpp"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>

#include <cmath>
#include <vector>

using namespace godot;

namespace {

// Coefficient columns per (temperature, band) in the packed table, and the absorbers they belong to.
constexpr int COEFFS = 11;
constexpr int PATH_COUNT = 10;
// Pressure layers the column is cut into, and bisection steps on the surface temperature.
constexpr int LAYERS = 40;
constexpr int BISECTIONS = 60;

// Which packed column each gas writes: its air-broadened lines, and a second column that is either its
// own self-broadened continuum (a further factor of its mole fraction) or a cross-section that does not
// broaden at all.
struct AbsorberColumn {
	const char *id;
	int line;
	int extra;
	bool extra_self_broadened;
};

const AbsorberColumn COLUMNS[] = {
	{ "co2", 0, 1, true },
	{ "h2o", 2, 3, true },
	{ "o3", 4, 5, false },
	{ "ch4", 6, -1, false },
	{ "co", 7, -1, false },
	{ "so2", 8, -1, false },
	{ "h2s", 9, -1, false },
};

// The packed band table, sliced once.
struct BandTable {
	int nb = 0;
	int nt = 0;
	double cdf_xmax = 0.0;
	std::vector<double> edges;
	std::vector<double> temps;
	std::vector<double> kappa;
	std::vector<double> cdf;
	bool ok = false;
};

const BandTable &band_table() {
	static BandTable t;
	if (t.ok || t.nb != 0) {
		return t;
	}
	const PackedFloat32Array packed = LAAbsorptionBands::packed();
	if (packed.size() < 4) {
		return t;
	}
	t.nb = int(packed[0]);
	const int cdf_count = int(packed[1]);
	t.cdf_xmax = double(packed[2]);
	t.nt = int(packed[3]);
	const int want = 4 + (t.nb + 1) + t.nt + t.nb + t.nt * t.nb * COEFFS + cdf_count;
	if (packed.size() != want || t.nb <= 0 || t.nt < 2) {
		t.nb = 0;
		return t;
	}
	int o = 4;
	for (int i = 0; i < t.nb + 1; i++) {
		t.edges.push_back(double(packed[o + i]));
	}
	o += t.nb + 1;
	for (int i = 0; i < t.nt; i++) {
		t.temps.push_back(double(packed[o + i]));
	}
	o += t.nt + t.nb; // the solar weights belong to the shortwave side
	for (int i = 0; i < t.nt * t.nb * COEFFS; i++) {
		t.kappa.push_back(double(packed[o + i]));
	}
	o += t.nt * t.nb * COEFFS;
	for (int i = 0; i < cdf_count; i++) {
		t.cdf.push_back(double(packed[o + i]));
	}
	t.ok = true;
	return t;
}

// Share of a blackbody's sigma T^4 above x = c2 nu / T, off the packed cumulative table.
double planck_above(const BandTable &t, double x) {
	if (x <= 0.0) {
		return 1.0;
	}
	if (x >= t.cdf_xmax) {
		return 0.0;
	}
	const double u = x / t.cdf_xmax * double(int(t.cdf.size()) - 1);
	const int i = int(u);
	const int j = std::min(i + 1, int(t.cdf.size()) - 1);
	return t.cdf[i] + (t.cdf[j] - t.cdf[i]) * (u - double(i));
}

double band_weight(const BandTable &t, int b, double tk, double c2) {
	const double lo = planck_above(t, c2 * t.edges[b] / tk);
	if (b + 1 >= t.nb) {
		return lo;
	}
	return std::max(lo - planck_above(t, c2 * t.edges[b + 1] / tk), 0.0);
}

double kappa_at(const BandTable &t, int b, int k, double tk) {
	int i = 0;
	double f = 0.0;
	if (tk <= t.temps[0]) {
		i = 0;
	} else if (tk >= t.temps[t.nt - 1]) {
		i = t.nt - 2;
	} else {
		while (i < t.nt - 2 && tk > t.temps[i + 1]) {
			i++;
		}
		f = (tk - t.temps[i]) / (t.temps[i + 1] - t.temps[i]);
	}
	const int o = b * COEFFS + k;
	const int stride = t.nb * COEFFS;
	return t.kappa[o + i * stride] + (t.kappa[o + (i + 1) * stride] - t.kappa[o + i * stride]) * f;
}

// flux.glsl's band_tau in column form: the CO2 line column carries its continuum on the same path.
double layer_tau(const BandTable &t, int b, double tk, const std::vector<double> &du) {
	double tau = (kappa_at(t, b, 0, tk) + kappa_at(t, b, 1, tk)) * du[0];
	for (int k = 1; k < PATH_COUNT; k++) {
		tau += kappa_at(t, b, k + 1, tk) * du[k];
	}
	return tau;
}

} // namespace

// Pressure-weighted equivalent path of a well-mixed absorber, q p_s^2 / (2 g p_ref) (Pierrehumbert,
// Principles of Planetary Climate, 4.2.2 — the reduction the band coefficients are stated in). A
// cross-section that does not broaden carries the plain column q p_s / g instead.
PackedFloat64Array LAColumnRadiation::absorber_paths(const Dictionary &p_air_x, double p_surface_pa,
		double p_g_m_s2) {
	PackedFloat64Array out;
	out.resize(PATH_COUNT);
	for (int i = 0; i < PATH_COUNT; i++) {
		out.set(i, 0.0);
	}
	const double p_ref = la_physical("ABSORPTION_REF_PRESSURE_PA");
	if (!(p_surface_pa > 0.0) || !(p_g_m_s2 > 0.0) || !(p_ref > 0.0)) {
		return out;
	}
	const Dictionary table = LASubstances::table();
	const Array names = p_air_x.keys();
	double m_air = 0.0;
	for (int i = 0; i < names.size(); i++) {
		m_air += double(p_air_x[names[i]])
				* double(Dictionary(table.get(names[i], Dictionary())).get("molar_mass", 0.0));
	}
	if (!(m_air > 0.0)) {
		return out;
	}
	const double broadened = p_surface_pa * p_surface_pa / (2.0 * p_g_m_s2 * p_ref);
	const double plain = p_surface_pa / p_g_m_s2;
	for (const AbsorberColumn &col : COLUMNS) {
		const double x = double(p_air_x.get(col.id, 0.0));
		if (!(x > 0.0)) {
			continue;
		}
		const double q = x * double(Dictionary(table.get(col.id, Dictionary())).get("molar_mass", 0.0))
				/ m_air;
		out.set(col.line, out[col.line] + q * broadened);
		if (col.extra < 0) {
			continue;
		}
		out.set(col.extra, out[col.extra] + (col.extra_self_broadened ? q * x * broadened : q * plain));
	}
	return out;
}

double LAColumnRadiation::adiabat_exponent(const Dictionary &p_air_x) {
	const Dictionary table = LASubstances::table();
	const Array names = p_air_x.keys();
	double cp_mol = 0.0;
	for (int i = 0; i < names.size(); i++) {
		const Dictionary row = table.get(names[i], Dictionary());
		cp_mol += double(p_air_x[names[i]]) * double(row.get("specific_heat_gas", 0.0))
				* double(row.get("molar_mass", 0.0));
	}
	return cp_mol > 0.0 ? la_physical("GAS_CONSTANT_J_MOL_K") / cp_mol : NAN;
}

// Grey Eddington: the top of the atmosphere runs at half the outgoing flux (Pierrehumbert ch. 4).
double LAColumnRadiation::skin_temp_k(double p_net_in_w_m2) {
	const double sigma = la_physical("STEFAN_BOLTZMANN");
	return p_net_in_w_m2 > 0.0 ? std::pow(0.5 * p_net_in_w_m2 / sigma, 0.25) : 0.0;
}

double LAColumnRadiation::outgoing_longwave_w_m2(double p_ts_k, double p_t_skin_k,
		const Dictionary &p_air_x, double p_surface_pa, double p_g_m_s2) {
	const BandTable &t = band_table();
	if (!t.ok || !(p_ts_k > 0.0)) {
		return NAN;
	}
	const double r_over_cp = adiabat_exponent(p_air_x);
	if (!std::isfinite(r_over_cp)) {
		return NAN;
	}
	const PackedFloat64Array paths = absorber_paths(p_air_x, p_surface_pa, p_g_m_s2);
	const double sigma = la_physical("STEFAN_BOLTZMANN");
	const double c2 = la_physical("PLANCK_C2_CM_K");
	const double diff = la_physical("TWO_STREAM_DIFFUSIVITY");
	// Equal increments of pressure from the top down: each layer's temperature on the dry adiabat, and
	// its share of the p^2-weighted column.
	std::vector<double> t_layer(LAYERS, 0.0), frac(LAYERS, 0.0);
	for (int k = 0; k < LAYERS; k++) {
		const double p_mid = (double(k) + 0.5) / double(LAYERS);
		t_layer[k] = std::max(p_ts_k * std::pow(p_mid, r_over_cp), p_t_skin_k);
		const double hi = (double(k) + 1.0) / double(LAYERS);
		const double lo = double(k) / double(LAYERS);
		frac[k] = hi * hi - lo * lo;
	}
	std::vector<double> du(PATH_COUNT, 0.0);
	double olr = 0.0;
	for (int b = 0; b < t.nb; b++) {
		double above = 0.0;
		double flux = 0.0;
		for (int k = 0; k < LAYERS; k++) {
			for (int a = 0; a < PATH_COUNT; a++) {
				du[a] = paths[a] * frac[k];
			}
			const double tk = t_layer[k];
			const double dtau = layer_tau(t, b, tk, du);
			flux += band_weight(t, b, tk, c2) * sigma * tk * tk * tk * tk
					* (1.0 - std::exp(-diff * dtau)) * std::exp(-diff * above);
			above += dtau;
		}
		flux += band_weight(t, b, p_ts_k, c2) * sigma * p_ts_k * p_ts_k * p_ts_k * p_ts_k
				* std::exp(-diff * above);
		olr += flux;
	}
	return olr;
}

// Bisection between the ends of the band table's own temperature range. The outgoing longwave rises
// with the surface temperature, so a net input outside what those ends radiate is UNBRACKETED and the
// answer is unmeasured, never the nearest end.
double LAColumnRadiation::equilibrium_temp_k(double p_net_in_w_m2, const Dictionary &p_air_x,
		double p_surface_pa, double p_g_m_s2) {
	const BandTable &t = band_table();
	if (!t.ok || !(p_net_in_w_m2 > 0.0)) {
		return NAN;
	}
	const double t_skin = skin_temp_k(p_net_in_w_m2);
	double lo = t.temps[0];
	double hi = t.temps[t.nt - 1];
	if (outgoing_longwave_w_m2(lo, t_skin, p_air_x, p_surface_pa, p_g_m_s2) > p_net_in_w_m2
			|| outgoing_longwave_w_m2(hi, t_skin, p_air_x, p_surface_pa, p_g_m_s2) < p_net_in_w_m2) {
		return NAN;
	}
	for (int i = 0; i < BISECTIONS; i++) {
		const double mid = 0.5 * (lo + hi);
		if (outgoing_longwave_w_m2(mid, t_skin, p_air_x, p_surface_pa, p_g_m_s2) < p_net_in_w_m2) {
			lo = mid;
		} else {
			hi = mid;
		}
	}
	return 0.5 * (lo + hi);
}

void LAColumnRadiation::_bind_methods() {
	ClassDB::bind_static_method("LAColumnRadiation",
			D_METHOD("absorber_paths", "air_mole_fractions", "surface_pa", "g_m_s2"),
			&LAColumnRadiation::absorber_paths);
	ClassDB::bind_static_method("LAColumnRadiation", D_METHOD("adiabat_exponent", "air_mole_fractions"),
			&LAColumnRadiation::adiabat_exponent);
	ClassDB::bind_static_method("LAColumnRadiation", D_METHOD("skin_temp_k", "net_in_w_m2"),
			&LAColumnRadiation::skin_temp_k);
	ClassDB::bind_static_method("LAColumnRadiation",
			D_METHOD("outgoing_longwave_w_m2", "ts_k", "t_skin_k", "air_mole_fractions", "surface_pa",
					"g_m_s2"),
			&LAColumnRadiation::outgoing_longwave_w_m2);
	ClassDB::bind_static_method("LAColumnRadiation",
			D_METHOD("equilibrium_temp_k", "net_in_w_m2", "air_mole_fractions", "surface_pa", "g_m_s2"),
			&LAColumnRadiation::equilibrium_temp_k);
}
