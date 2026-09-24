#include "LAFieldLithostaticSeed.hpp"

#include "LAFieldMirrors.hpp"
#include "LAParallel.hpp"

#include "LABodySystem.hpp"
#include "LAFieldHydrosphereSeed.hpp"
#include "LAMixtureEnthalpy.hpp"
#include "LAPhaseEos.hpp"
#include "LAPhysicalRead.hpp"
#include "LAProcessSet.hpp"
#include "LAScriptCall.hpp"
#include "LASubstances.hpp"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <godot_cpp/variant/utility_functions.hpp>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <functional>
#include <limits>
#include <thread>
#include <vector>

using namespace godot;

namespace {

const char *CHANNELS_GD = "res://addons/local_agents/sim/material/Channels.gd";
const char *GEOMETRY_GD = "res://addons/local_agents/sim/material/FieldGeometry3D.gd";
const char *MATTER_GD = "res://addons/local_agents/sim/material/MatterChannels.gd";

// Halvings that take any double interval to one ulp: a solve below settles within this many or states no
// answer.
constexpr int HALVINGS = std::numeric_limits<double>::max_exponent + std::numeric_limits<double>::digits;

// One cell's matter as la_eos_p reads it: condensed volume B, the fluid's compressibility C, the gas's
// n R T and Peng-Robinson sums, and the room the gas stands in.
struct FluidSums {
	double b = 0.0;      // m^3
	double c = 0.0;      // m^3/Pa
	double a_rt = 0.0;   // J
	double s_a = 0.0;    // sum n sqrt(a(T))
	double s_b = 0.0;    // sum n b, m^3
	double room = 0.0;   // m^3
};

Vector3 field_centre(Object *p_field) {
	Array args;
	args.append(p_field);
	return la_call_gd(GEOMETRY_GD, "centre", args);
}

// A channel mirror, held by NAME so it can be written back: a godot-cpp Packed array is copy-on-write, so
// mutating the local never reaches the field on its own.
struct Mirror {
	String name;
	String substance;
	PackedFloat32Array arr;
};

// Every channel whose row answers `p_value` under `p_key` and whose mirror is the right size. `p_value`
// empty means the row's flag is a bool that must be true.
std::vector<Mirror> channel_mirrors(Object *p_field, const String &p_key, const String &p_value) {
	std::vector<Mirror> out;
	const Dictionary rows = la_call_gd(CHANNELS_GD, "rows", Array());
	const int cc = int(p_field->get("_cell_count"));
	const Array names = rows.keys();
	for (int i = 0; i < names.size(); i++) {
		const String name = names[i];
		const Dictionary row = rows[name];
		const bool wanted = p_value.is_empty() ? bool(row.get(p_key, false))
											 : String(row.get(p_key, "")) == p_value;
		if (!wanted) {
			continue;
		}
		const PackedFloat32Array arr = LAFieldMirrors::of(p_field, name);
		if (arr.size() != cc) {
			continue;
		}
		out.push_back({ name, String(row.get("substance", "")), arr });
	}
	return out;
}

// A CUBE READ ALONG THE LOCAL VERTICAL. s runs from the cube's lowest point to its highest, so the share
// of its volume below s is the distribution of n_0 U_0 + n_1 U_1 + n_2 U_2 -- the three edges' projections
// on the vertical against uniform U -- and the section's area is that distribution's density.
struct CubeColumn {
	double n[3] = { 0.0, 0.0, 0.0 };   // edge projections on the vertical, m
	int k = 0;
	double span = 0.0;                 // the cube's extent along the vertical, m
};

CubeColumn cube_column(double p_edge, const Vector3 &p_up) {
	double n[3] = { std::abs(double(p_up.x)) * p_edge, std::abs(double(p_up.y)) * p_edge,
		std::abs(double(p_up.z)) * p_edge };
	std::sort(n, n + 3, std::greater<double>());
	// An edge nearly square to the vertical is divided by in the section, and under this share of the
	// span the cancellation that costs outweighs the width it carries; the span stays centred without it.
	const double zeta = std::pow(std::numeric_limits<double>::epsilon(), 0.25);
	const double whole = n[0] + n[1] + n[2];
	CubeColumn col;
	for (int i = 0; i < 3; i++) {
		if (n[i] > zeta * whole) {
			col.n[col.k++] = n[i];
			col.span += n[i];
		}
	}
	return col;
}

// The share of the cube's volume below the level s.
double column_below(const CubeColumn &p_col, double p_s) {
	if (p_col.k <= 0) {
		return p_s > 0.0 ? 1.0 : 0.0;
	}
	double prod = 1.0;
	for (int i = 0; i < p_col.k; i++) {
		prod *= p_col.n[i];
	}
	const double fact = p_col.k == 3 ? 6.0 : (p_col.k == 2 ? 2.0 : 1.0);
	double sum = 0.0;
	for (int m = 0; m < (1 << p_col.k); m++) {
		double t = p_s;
		int bits = 0;
		for (int i = 0; i < p_col.k; i++) {
			if (m & (1 << i)) {
				t -= p_col.n[i];
				bits++;
			}
		}
		if (!(t > 0.0)) {
			continue;
		}
		double term = 1.0;
		for (int j = 0; j < p_col.k; j++) {
			term *= t;
		}
		sum += (bits & 1) ? -term : term;
	}
	return sum / (fact * prod);
}

// The section at s, share of the cube's volume per metre, as a polynomial in t = s - p_s0. Which corners
// the segment stands past is decided at p_mid, so a term whose breakpoint IS p_s0 is not lost to rounding.
void column_section(const CubeColumn &p_col, double p_s0, double p_mid, double p_a[3]) {
	p_a[0] = p_a[1] = p_a[2] = 0.0;
	if (p_col.k <= 0) {
		return;
	}
	double prod = 1.0;
	for (int i = 0; i < p_col.k; i++) {
		prod *= p_col.n[i];
	}
	const double fact = p_col.k == 3 ? 2.0 : 1.0;
	for (int m = 0; m < (1 << p_col.k); m++) {
		double corner = 0.0;
		int bits = 0;
		for (int i = 0; i < p_col.k; i++) {
			if (m & (1 << i)) {
				corner += p_col.n[i];
				bits++;
			}
		}
		if (!(p_mid > corner)) {
			continue;
		}
		const double sgn = (bits & 1) ? -1.0 : 1.0;
		const double base = p_s0 - corner;
		if (p_col.k == 1) {
			p_a[0] += sgn;
		} else if (p_col.k == 2) {
			p_a[0] += sgn * base;
			p_a[1] += sgn;
		} else {
			p_a[0] += sgn * base * base;
			p_a[1] += sgn * 2.0 * base;
			p_a[2] += sgn;
		}
	}
	for (int j = 0; j < 3; j++) {
		p_a[j] /= fact * prod;
	}
}

// The n-point Gauss-Legendre rule on [-1, 1]: Newton on P_n from the Chebyshev guess, per thread.
const std::vector<double> &gauss_legendre(int p_n) {
	thread_local std::vector<std::vector<double>> rules;
	if (int(rules.size()) <= p_n) {
		rules.resize(p_n + 1);
	}
	std::vector<double> &r = rules[p_n];
	if (!r.empty()) {
		return r;
	}
	r.assign(2 * p_n, 0.0);   // node, weight, node, weight...
	for (int i = 0; i < (p_n + 1) / 2; i++) {
		double x = std::cos(Math::PI * (double(i) + 0.75) / (double(p_n) + 0.5));
		double dp = 1.0;
		for (int it = 0; it < 100; it++) {
			double p0 = 1.0, p1 = x;
			for (int k = 2; k <= p_n; k++) {
				const double p2 = ((2.0 * k - 1.0) * x * p1 - (k - 1.0) * p0) / double(k);
				p0 = p1;
				p1 = p2;
			}
			const double pn = p_n == 1 ? x : p1;
			const double pm = p_n == 1 ? 1.0 : p0;
			dp = double(p_n) * (x * pn - pm) / (x * x - 1.0);
			const double dx = pn / dp;
			x -= dx;
			if (std::abs(dx) <= std::numeric_limits<double>::epsilon() * std::abs(x)) {
				break;
			}
		}
		const double w = 2.0 / ((1.0 - x * x) * dp * dp);
		r[2 * i] = -x;
		r[2 * i + 1] = w;
		r[2 * (p_n - 1 - i)] = x;
		r[2 * (p_n - 1 - i) + 1] = w;
	}
	return r;
}

// Bernstein-ellipse parameters tau = ln rho the bound is minimised over. Any tau > 0 is a valid bound;
// the set decides only how tight it is.
struct EllipseSet {
	double tau[25], cosh_tau[25], log_rho2m1[25];
	EllipseSet() {
		for (int k = 0; k < 25; k++) {
			tau[k] = std::pow(2.0, 0.5 * double(k)) / 32.0;
			cosh_tau[k] = std::cosh(tau[k]);
			log_rho2m1[k] = std::log(std::expm1(2.0 * tau[k]));
		}
	}
};

// WHAT ONE CELL'S GAS WEIGHS AGAINST THE DATUM'S: exp(-(phi - phi_0) / (R T / M)) integrated over the
// volume the cell's rock and sea leave, over the cell's whole volume. The gas stands on them, so the room
// is the cube above the level that leaves p_cut of it below, in the potential of the monopole this cell's
// own gravity states. Each segment between the section's breakpoints is a polynomial times an entire
// exponential, taken by Gauss-Legendre at the node count whose error bound holds to float precision
// against a lower bound of the segment's own integral. The bound: Chebyshev coefficients |a_k| <=
// 2 M rho^-k for |f| <= M on the Bernstein ellipse (Trefethen, ATAP Thm 8.1); the n-point rule is exact
// below T_2n and odd T_k vanish, and |I(T_k) - I_n(T_k)| <= 2 + 2 / (k^2 - 1), so
// |I - I_n| <= 4 M (1 + 1 / (4 n^2 - 1)) rho^(2 - 2n) / (rho^2 - 1). NAN when no count can.
double cell_air_share(const CubeColumn &p_col, double p_cut, double p_phi_c, double p_phi_0,
		double p_g, double p_r, double p_rt) {
	static const EllipseSet ELLIPSES;
	const double log_eps32 = std::log(double(std::numeric_limits<float>::epsilon()));
	// Past this many terms the double sum's own rounding reaches float precision.
	const double n_cap = double(std::numeric_limits<float>::epsilon()) / std::numeric_limits<double>::epsilon();
	const double half = 0.5 * p_col.span;
	const double gm_eff = p_g * p_r * p_r;
	const bool radial = p_r > p_col.span;
	// The exponent, decreasing in z: its real part on the ellipse is bounded by its value at the lowest z.
	auto exponent = [&](double z) {
		return radial ? -((p_phi_c - p_phi_0) + gm_eff * z / (p_r * (p_r + z))) / p_rt
					  : -((p_phi_c - p_phi_0) + p_g * z) / p_rt;
	};
	double bp[10];
	int nb = 0;
	bp[nb++] = p_cut;
	for (int m = 1; m < (1 << p_col.k) - 1; m++) {
		double v = 0.0;
		for (int i = 0; i < p_col.k; i++) {
			if (m & (1 << i)) {
				v += p_col.n[i];
			}
		}
		if (v > p_cut && v < p_col.span) {
			bp[nb++] = v;
		}
	}
	bp[nb++] = p_col.span;
	std::sort(bp, bp + nb);
	double out = 0.0;
	for (int b = 0; b + 1 < nb; b++) {
		const double len = bp[b + 1] - bp[b];
		if (!(len > 0.0)) {
			continue;
		}
		const double h = 0.5 * len;
		const double zm = bp[b] + h - half;
		double a[3];
		column_section(p_col, bp[b], bp[b] + h, a);
		const double area = a[0] * len + a[1] * len * len / 2.0 + a[2] * len * len * len / 3.0;
		if (!(area > 0.0)) {
			continue;
		}
		// The section is non-negative, so the exponent's least value times its integral bounds I below.
		const double log_tol = log_eps32 + exponent(zm + h) + std::log(area);
		auto log_bound = [&](int k, double n) -> double {
			const double reach = h * ELLIPSES.cosh_tau[k];
			if (radial && !(p_r + zm - reach > 0.0)) {
				return INFINITY;
			}
			const double t = h + reach;
			const double a_max = std::abs(a[0]) + std::abs(a[1]) * t + std::abs(a[2]) * t * t;
			return std::log(4.0 * (1.0 + 1.0 / (4.0 * n * n - 1.0))) + std::log(h * a_max) + exponent(zm - reach)
					+ (2.0 - 2.0 * n) * ELLIPSES.tau[k] - ELLIPSES.log_rho2m1[k];
		};
		double n_need = INFINITY;
		for (int k = 0; k < 25; k++) {
			// log_bound(k, n) <= log_bound(k, 1) - (2n - 2) tau.
			const double excess = log_bound(k, 1.0) - log_tol;
			n_need = std::min(n_need, 1.0 + std::ceil(std::max(excess, 0.0) / (2.0 * ELLIPSES.tau[k])));
		}
		if (!(n_need <= n_cap)) {
			return NAN;
		}
		const int n = int(n_need);
		bool held = false;
		for (int k = 0; k < 25 && !held; k++) {
			held = n >= 1 && log_bound(k, double(n)) <= log_tol;
		}
		if (!held) {
			return NAN;
		}
		const std::vector<double> &rule = gauss_legendre(n);
		double sum = 0.0;
		for (int i = 0; i < n; i++) {
			const double x = rule[2 * i];
			const double t = h * (1.0 + x);
			sum += rule[2 * i + 1] * (a[0] + a[1] * t + a[2] * t * t) * std::exp(exponent(zm + h * x));
		}
		out += h * sum;
	}
	return out;
}

} // namespace

PackedFloat32Array LAFieldLithostaticSeed::vertical(Object *p_field,
		const PackedFloat32Array &p_gravity) {
	const int cc = p_field ? int(p_field->get("_cell_count")) : 0;
	if (LAProcessSet::has_record("pass", "PressurePass.gd", LAProcessSet::ANY)
			&& p_gravity.size() == cc * 3) {
		return p_gravity;
	}
	PackedFloat32Array z;
	z.resize(MAX(cc, 0) * 3);
	z.fill(0.0f);
	return z;
}

Dictionary LAFieldLithostaticSeed::compress(Object *p_field, const PackedFloat32Array &p_g_rest,
		const PackedFloat32Array &p_t_rock, const PackedFloat32Array &p_pore_air) {
	if (!p_field) {
		return Dictionary();
	}
	Object *grid = Object::cast_to<Object>(p_field->get("_grid"));
	const int cc = int(p_field->get("_cell_count"));
	const PackedByteArray solid = p_field->get("_solid");
	if (!grid || cc <= 0 || solid.size() != cc) {
		return Dictionary();
	}
	const PackedFloat32Array edges = grid->call("cell_edges");
	const PackedFloat32Array rock_fr = p_field->get("_rock_fraction");
	PackedFloat32Array porosity = LAFieldMirrors::of(p_field, "porosity");
	ERR_FAIL_COND_V_MSG(p_g_rest.size() != cc * 3 || p_t_rock.size() != cc || edges.size() != cc
					|| rock_fr.size() != cc || porosity.size() != cc,
			Dictionary(), "LAFieldLithostaticSeed.compress: the solved gravity, the rock temperature, the cell "
			"edges, the rock fractions or the porosity do not cover the " + String::num_int64(cc)
			+ " cells, so no cell has a state to be sized at.");
	const double t_c = LABodySeeds::surface_temp_c();
	const double kelvin = la_physical("KELVIN_OFFSET");
	const double r_gas = la_physical("GAS_CONSTANT_J_MOL_K");
	const double p_std = la_physical("STANDARD_PRESSURE_PA");
	// The float32 state's resolution.
	const double eps = double(std::numeric_limits<float>::epsilon());

	// RESOLUTION FOLLOWS POSITION: a cell's edge, volume and gravity are its own. g_mag is the |g| the derive
	// weighs an open cell's lattice by; g_step is kernels3d/pressure.glsl's la_load per kg/m^3 along the
	// solved gravity, which weighs the rock on every rung that has gravity.
	std::vector<double> edge(cc, 0.0), vol(cc, 0.0), g_mag(cc, 0.0), g_step(cc, 0.0);
	bool pulled = false;
	for (int c = 0; c < cc; c++) {
		edge[c] = double(edges[c]);
		vol[c] = edge[c] * edge[c] * edge[c];
		const Vector3 gv(p_g_rest[c * 3], p_g_rest[c * 3 + 1], p_g_rest[c * 3 + 2]);
		g_mag[c] = double(gv.length());
		if (g_mag[c] > 0.0) {
			const Vector3 up = -gv / float(g_mag[c]);
			g_step[c] = g_mag[c] * edge[c] * double(MAX(MAX(std::abs(up.x), std::abs(up.y)), std::abs(up.z)));
			pulled = true;
		}
	}
	// THE ONE VERTICAL RELATION, GravityPass's, which pressure.glsl walks.
	Object *gravity = Object::cast_to<Object>(p_field->get("_gravity"));
	const PackedInt32Array up_of = gravity ? PackedInt32Array(gravity->call("up_table")) : PackedInt32Array();
	ERR_FAIL_COND_V_MSG(pulled && up_of.size() != cc, Dictionary(), "LAFieldLithostaticSeed.compress: gravity "
			"is solved and the vertical relation is not, so no column can stand over the rock.");
	const bool column = up_of.size() == cc;
	const int walk_max = 3 * int(grid->call("max_span"));

	// Every matter channel, with what the substance table says about the substance it carries. The lattice
	// is the rock's grains and the water in their pores; a solute rides in its solvent; the rest is the
	// fluid's. A substance with a heat buffer of its own raises its vapour over itself, as the derive books it.
	enum Kind { GAS, GRAIN, PORE, SOLUTE, CONDENSED };
	struct Chan {
		Kind kind = CONDENSED;
		double mm = 0.0;
		bool vapour = false;
		const LACondensedEos *eos = nullptr;
		const LAFluidEos *fl = nullptr;
		String sub;
	};
	const Dictionary table = LASubstances::table();
	const Dictionary rows = la_call_gd(CHANNELS_GD, "rows", Array());
	const Dictionary carriers = la_gd_const(MATTER_GD, "CARRIERS");
	std::vector<Mirror> mats = channel_mirrors(p_field, "unit", "mol_m3");
	const size_t nm = mats.size();
	std::vector<Chan> ch(nm);
	std::vector<float *> amt(nm, nullptr);
	for (size_t i = 0; i < nm; i++) {
		const Dictionary row = rows.get(mats[i].name, Dictionary());
		Chan &k = ch[i];
		k.sub = mats[i].substance;
		k.mm = double(Dictionary(table.get(k.sub, Dictionary())).get("molar_mass", 0.0));
		const String phase = row.get("phase", "");
		k.kind = phase == "gas" ? GAS
				: bool(row.get("lithic", false)) ? GRAIN
				: bool(row.get("lattice", false)) ? PORE
				: phase == "dissolved" ? SOLUTE : CONDENSED;
		const LAFluidEos &fl = LAPhaseEosFn::fluid(k.sub);
		k.fl = fl.valid ? &fl : nullptr;
		ERR_FAIL_COND_V_MSG(k.kind == GAS && !k.fl, Dictionary(), "LAFieldLithostaticSeed: gas \"" + k.sub
				+ "\" has no fluid equation of state.");
		if (k.kind == GRAIN || k.kind == PORE || k.kind == CONDENSED) {
			k.eos = &LAPhaseEosFn::condensed(k.sub);
		}
		k.vapour = (k.kind == PORE || k.kind == CONDENSED) && carriers.has(k.sub) && k.fl;
		amt[i] = mats[i].arr.ptrw();
	}

	// kg/m^3 of all matter and of the lattice: gravity pulls on all of it, and the lattice carries its own.
	std::vector<double> rho(cc, 0.0), rho_lat(cc, 0.0);
	auto weigh = [&](int c) {
		rho[c] = 0.0;
		rho_lat[c] = 0.0;
		for (size_t i = 0; i < nm; i++) {
			const double n = double(amt[i][c]);
			if (n > 0.0) {
				rho[c] += n * ch[i].mm;
				rho_lat[c] += (ch[i].kind == GRAIN || ch[i].kind == PORE) ? n * ch[i].mm : 0.0;
			}
		}
	};
	// A cell holds fluid where it holds gas, pore water or any other condensed phase than the grains.
	auto holds_fluid = [&](int c) {
		for (size_t i = 0; i < nm; i++) {
			if ((ch[i].kind == GAS || ch[i].kind == PORE || ch[i].kind == CONDENSED) && amt[i][c] > 0.0f) {
				return true;
			}
		}
		return false;
	};
	// The seed's two reservoirs: the lattice at the rock's geotherm, the fluid at the surface's; gas in rock
	// with no free surface at the rock's own, as LAFieldCellMass3D.seed_enthalpy lays it.
	auto t_gas_of = [&](int c) { return double(rock_fr[c]) < 1.0 ? t_c : double(p_t_rock[c]); };

	// WHAT ONE CELL'S MATTER STATES AT PRESSURE p: its grains at the rock's own (T, p_rock); its pore water
	// in the fluid at p where `pore_fluid`, its own equation of state holding it, and otherwise the
	// lattice's at p_rock as state_derive.glsl books it; every other condensed phase at the fluid's p, their
	// vapours at saturation in the room they leave at their own temperature, the gas in that room. b is NaN
	// where a phase present has no measured volume at its state.
	struct Part {
		double m, v, k, t;
		int i;
	};
	std::vector<Part> parts;
	auto sums_at = [&](int c, double p, double p_rock, bool pore_fluid) -> FluidSums {
		FluidSums s;
		const double v = vol[c];
		const double t_lat = double(p_t_rock[c]);
		const double t_gas = t_gas_of(c) + kelvin;
		double v_lat = 0.0;
		parts.clear();
		for (size_t i = 0; i < nm; i++) {
			const double n = double(amt[i][c]);
			if (!(n > 0.0) || ch[i].kind == SOLUTE) {
				continue;
			}
			if (ch[i].kind == GAS) {
				const double mol = n * v;
				s.a_rt += mol * r_gas * t_gas;
				s.s_a += mol * std::sqrt(LAPhaseEosFn::pr_a(*ch[i].fl, t_gas));
				s.s_b += mol * ch[i].fl->b;
				continue;
			}
			const bool lat = ch[i].kind == GRAIN || (ch[i].kind == PORE && !pore_fluid);
			const double t_here = ch[i].kind == CONDENSED ? t_c : t_lat;
			const double spec = LAPhaseEosFn::condensed_volume(*ch[i].eos, t_here, lat ? p_rock : p);
			if (!(spec > 0.0)) {
				s.b = NAN;
				return s;
			}
			const double m = n * v * ch[i].mm;
			if (lat) {
				v_lat += m * spec;
				continue;
			}
			parts.push_back({ m, spec, LAPhaseEosFn::condensed_compressibility(*ch[i].eos, t_here, p), t_here,
					int(i) });
		}
		// The vapours' room is what their own condensed volume leaves, so the two settle together.
		double room = v - v_lat;
		double b_free = 0.0, c_free = 0.0, a_vap = 0.0, sa_vap = 0.0, sb_vap = 0.0;
		bool settled = false;
		for (int it = 0; it < HALVINGS && !settled; it++) {
			b_free = c_free = a_vap = sa_vap = sb_vap = 0.0;
			for (const Part &q : parts) {
				const Chan &k = ch[q.i];
				const double fv = (k.vapour && room > 0.0)
						? LAMixtureEnthalpy::vapour_fraction(k.sub, q.t, p, q.m, room) : 0.0;
				b_free += q.m * (1.0 - fv) * q.v;
				c_free += q.m * (1.0 - fv) * q.k;
				if (fv > 0.0) {
					const double nv = q.m * fv / k.mm;
					const double tk = q.t + kelvin;
					a_vap += nv * r_gas * tk;
					sa_vap += nv * std::sqrt(LAPhaseEosFn::pr_a(*k.fl, tk));
					sb_vap += nv * k.fl->b;
				}
			}
			// The room is the cell less what fills it, so it is known to the cell's volume, not its own.
			const double next = v - v_lat - b_free;
			settled = next == room || std::abs(next - room) <= eps * v;
			room = next;
		}
		s.b = settled ? v_lat + b_free : NAN;
		s.c = c_free;
		s.a_rt += a_vap;
		s.s_a += sa_vap;
		s.s_b += sb_vap;
		s.room = room;
		return s;
	};
	auto p_eos = [&](int c, double p, double p_rock, bool pore_fluid) -> double {
		const FluidSums s = sums_at(c, p, p_rock, pore_fluid);
		return std::isnan(s.b) ? NAN
							   : LAPhaseEosFn::mixture_pressure(vol[c], s.a_rt, s.s_a, s.s_b, s.b, s.c, p);
	};
	// The lattice's pressure, state_derive.glsl's p_rock: the load a locked cell's rock carries, and in an
	// open one the fluid's plus half its own lattice's weight.
	std::vector<double> p_open(cc, 0.0), p_col(cc, 0.0), p_fl(cc, 0.0);
	auto rock_at = [&](int c, double p) {
		return solid[c] != 0 ? p_col[c] : p + 0.5 * rho_lat[c] * g_mag[c] * edge[c];
	};
	// THE PRESSURE A CELL'S MATTER STATES: the root of p_eos(p) = p, which falls as p rises. Secant steps
	// through the last two readings, within a doubling or a halving of p, and the fixed point's own step
	// otherwise, until the root is bracketed; then halving wherever a step leaves the bracket or fails to
	// halve it.
	auto solve = [&](int c, bool pore_fluid) -> double {
		double lo = 0.0, hi = 0.0;
		bool has_lo = false, has_hi = false;
		double p = p_std, p_prev = NAN, f_prev = NAN;
		double width = INFINITY;
		for (int it = 0; it < 2 * HALVINGS; it++) {
			const double pe = p_eos(c, p, rock_at(c, p), pore_fluid);
			if (!std::isfinite(pe)) {
				return NAN;
			}
			const double f = pe - p;
			if (f == 0.0 || std::abs(f) <= eps * p) {
				return p;
			}
			if (f > 0.0) {
				lo = p;
				has_lo = true;
			} else {
				hi = p;
				has_hi = true;
			}
			const double secant = std::isfinite(f_prev) && f != f_prev ? p - f * (p - p_prev) / (f - f_prev) : NAN;
			double step = secant >= 0.5 * p && secant <= 2.0 * p ? secant : pe;
			p_prev = p;
			f_prev = f;
			if (has_lo && has_hi) {
				if (hi - lo <= eps * hi) {
					return 0.5 * (lo + hi);
				}
				if (!(step > lo && step < hi) || hi - lo > 0.5 * width) {
					step = 0.5 * (lo + hi);
				}
				width = hi - lo;
			}
			p = step;
		}
		return NAN;
	};
	// ROCK BESIDE FLUID IS ITS GRAINS AT THEIR OWN STATE: they fill (1 - porosity) of the rock's volume at the
	// rock's (T, p_rock), and the pores and the room over the ground the rest. The composition laid them at
	// the radial profile's pressure, so wherever a cell holds fluid or pores they are sized again at the
	// load they stand under. Returns the factor they moved by.
	bool relaid = false;
	auto relay = [&](int c, double p_rock) -> double {
		const double phi = double(porosity[c]);
		const double f = double(rock_fr[c]);
		if (!(f > 0.0) || (!(phi > 0.0) && !holds_fluid(c))) {
			return 1.0;
		}
		double v_now = 0.0;
		for (size_t i = 0; i < nm; i++) {
			const double n = double(amt[i][c]);
			if (ch[i].kind == GRAIN && n > 0.0) {
				v_now += n * ch[i].mm * LAPhaseEosFn::condensed_volume(*ch[i].eos, double(p_t_rock[c]), p_rock);
			}
		}
		if (!(v_now > 0.0)) {
			return NAN;
		}
		const double k = (1.0 - phi) * f / v_now;
		for (size_t i = 0; i < nm; i++) {
			if (ch[i].kind == GRAIN) {
				amt[i][c] = float(double(amt[i][c]) * k);
			}
		}
		weigh(c);
		relaid = true;
		return k;
	};

	for (int c = 0; c < cc; c++) {
		weigh(c);
	}
	// THE PORES CLOSE UNDER THE LOAD THEIR FRAME CARRIES: phi_0 exp(-sigma' / P_c) at sigma' the lattice's
	// load less its pore fluid's pressure (Terzaghi's effective stress). The water and the air laid in them
	// stand at densities their porosity does not set, so a cell's pore water and pore air move with it.
	// LA_APPROX: porosity_at_centre_load
	const PackedByteArray regolith = p_field->get("_regolith");
	const bool compacts = p_pore_air.size() == cc && regolith.size() == cc;
	const double phi_0 = la_physical("CRUST_SURFACE_POROSITY");
	const double p_close = la_physical("CRUST_POROSITY_CLOSURE_PA");
	std::vector<double> pore_air(cc, 0.0);
	for (int c = 0; compacts && c < cc; c++) {
		pore_air[c] = double(p_pore_air[c]);
	}
	bool compacted = false;
	// One closing step at an effective load: true while the porosity still moves by less each step than the
	// last, which ends where the float32 amounts no longer resolve the load.
	auto close = [&](int c, double p_sigma, double &r_last) -> bool {
		if (!compacts || regolith[c] == 0) {
			return false;
		}
		const double was = double(porosity[c]);
		const double next = phi_0 * std::exp(-p_sigma / p_close);
		const double moved = std::abs(next - was) / next;
		if (!(was > 0.0) || moved <= eps || !(moved < r_last)) {
			return false;
		}
		r_last = moved;
		const double r = next / was;
		const double keep = 1.0 - pore_air[c] + pore_air[c] * r;
		for (size_t i = 0; i < nm; i++) {
			if (ch[i].kind == PORE) {
				amt[i][c] = float(double(amt[i][c]) * r);
			} else if (ch[i].kind == GAS) {
				amt[i][c] = float(double(amt[i][c]) * keep);
			}
		}
		pore_air[c] = keep > 0.0 ? pore_air[c] * r / keep : 0.0;
		porosity.set(c, float(next));
		weigh(c);
		compacted = true;
		return true;
	};
	// AN OPEN CELL STANDS AT THE PRESSURE ITS OWN MATTER STATES, the derive's own rule.
	for (int c = 0; c < cc; c++) {
		if (solid[c] != 0 || !(rho[c] > 0.0)) {
			continue;
		}
		bool settled = false;
		double last = INFINITY;
		for (int round = 0; round < HALVINGS && !settled; round++) {
			p_open[c] = solve(c, false);
			const double k = std::isnan(p_open[c]) ? NAN : relay(c, rock_at(c, p_open[c]));
			ERR_FAIL_COND_V_MSG(std::isnan(k), Dictionary(), "LAFieldLithostaticSeed: open cell "
					+ String::num_int64(c) + " overfilled by incompressible matter, a gas packed past its "
					"co-volume, or rock beside fluid with no grains, states no pressure.");
			settled = std::abs(k - 1.0) <= eps && !close(c, rock_at(c, p_open[c]) - p_open[c], last);
		}
		ERR_FAIL_COND_V_MSG(!settled, Dictionary(), "LAFieldLithostaticSeed: open cell " + String::num_int64(c)
				+ "'s grains did not settle at the load they stand under.");
	}
	// THE COLUMN, walked as kernels3d/pressure.glsl walks it: half this cell's own load, the whole load of
	// every locked cell up the one vertical relation, and the pressure of the first open cell over them with
	// what it holds under it: its lattice whole, its fluid from its mean.
	auto walk = [&](int c) {
		double acc = 0.5 * rho[c] * g_step[c];
		double top = 0.0;
		int a = column ? up_of[c] : -1;
		for (int k = 0; k < walk_max && a >= 0; k++) {
			if (solid[a] == 0) {
				top = p_open[a] + 0.5 * (rho[a] + rho_lat[a]) * g_step[a];
				break;
			}
			acc += rho[a] * g_step[a];
			a = up_of[a];
		}
		return top + acc;
	};
	// Locked cells down each column, a level at a time, so every load over a cell is final before its own
	// is walked.
	std::vector<std::vector<int>> levels;
	{
		std::vector<int> up(cc, -1);
		std::vector<char> in(cc, 0);
		for (int c = 0; c < cc; c++) {
			up[c] = column ? up_of[c] : -1;
			in[c] = solid[c] != 0;
		}
		ERR_FAIL_COND_V_MSG(!la_column_levels(up, in, levels), Dictionary(), "LAFieldLithostaticSeed.compress: "
				"the vertical relation closes on itself, so no column has a top.");
	}
	// A LOCKED CELL's fluid stands at the pressure its own equation of state gives it in the room the grains
	// leave: in rock with no free surface that fluid is the pores' own, their water with it; beside a free
	// surface it is the sea and air there, the pore water the lattice's. Its rock carries the column over its
	// centre on every rung, whether or not the hydrostatic rung steps that column.
	for (const std::vector<int> &level : levels) {
		for (const int c : level) {
			const bool fluid = holds_fluid(c);
			const bool pore_fluid = !(double(rock_fr[c]) < 1.0);
			bool closed = false;
			double last = INFINITY;
			for (int step = 0; step < HALVINGS && !closed; step++) {
				bool settled = false;
				for (int round = 0; round < HALVINGS && !settled; round++) {
					p_col[c] = walk(c);
					const double k = relay(c, p_col[c]);
					ERR_FAIL_COND_V_MSG(std::isnan(k), Dictionary(), "LAFieldLithostaticSeed: locked cell "
							+ String::num_int64(c) + " holds rock beside fluid with no grains to size at its load.");
					settled = std::abs(k - 1.0) <= eps;
				}
				ERR_FAIL_COND_V_MSG(!settled, Dictionary(), "LAFieldLithostaticSeed: locked cell "
						+ String::num_int64(c) + "'s grains did not settle at the load they stand under.");
				p_col[c] = walk(c);
				if (fluid) {
					p_fl[c] = solve(c, pore_fluid);
					ERR_FAIL_COND_V_MSG(std::isnan(p_fl[c]), Dictionary(), "LAFieldLithostaticSeed: locked cell "
							+ String::num_int64(c) + "'s fluid states no pressure in the room its grains leave.");
				}
				closed = !close(c, p_col[c] - p_fl[c], last);
			}
			ERR_FAIL_COND_V_MSG(!closed, Dictionary(), "LAFieldLithostaticSeed: locked cell "
					+ String::num_int64(c) + "'s pores did not close at the load they stand under.");
		}
	}
	if (compacted) {
		for (size_t i = 0; i < nm; i++) {
			if (ch[i].kind == PORE || ch[i].kind == GAS) {
				LAFieldMirrors::store(p_field, mats[i].name, mats[i].arr);
			}
		}
		LAFieldMirrors::store(p_field, "porosity", porosity);
	}
	if (relaid) {
		for (size_t i = 0; i < nm; i++) {
			if (ch[i].kind == GRAIN) {
				LAFieldMirrors::store(p_field, mats[i].name, mats[i].arr);
			}
		}
	}

	// What each cell states: an open cell's pressure is its own matter's; a locked cell's is the column its
	// rock carries beside the pressure its fluid stands at. `room` is the gas's, as the derive reads it.
	PackedFloat32Array out, p_fluid, p_rock, room;
	out.resize(cc);
	p_fluid.resize(cc);
	p_rock.resize(cc);
	room.resize(cc);
	float *w = out.ptrw();
	float *pf = p_fluid.ptrw();
	float *pr = p_rock.ptrw();
	float *rw = room.ptrw();
	for (int c = 0; c < cc; c++) {
		const bool open = solid[c] == 0;
		const double p = open ? p_open[c] : p_fl[c];
		const double rock = rock_at(c, p);
		w[c] = float(open ? p : p_col[c]);
		pf[c] = float(p);
		pr[c] = float(rock);
		rw[c] = float(rho[c] > 0.0 ? sums_at(c, p, rock, false).room : 0.0);
		ERR_FAIL_COND_V_MSG(!std::isfinite(w[c]) || !std::isfinite(pf[c]) || !std::isfinite(pr[c]), Dictionary(),
				"LAFieldLithostaticSeed: cell " + String::num_int64(c) + " states a pressure past the field's "
				"float range.");
	}
	Dictionary both;
	both["pressure"] = out;
	both["fluid"] = p_fluid;
	both["rock"] = p_rock;
	both["room"] = room;
	return both;
}

Dictionary LAFieldLithostaticSeed::settle(Object *p_field, double p_temp_c, const PackedFloat32Array &p_g_rest,
		const PackedFloat64Array &p_phi, const PackedFloat32Array &p_t_rock) {
	// Below the hydrostatic rung no air is laid, and no pore holds any.
	const Dictionary air = shape_atmosphere(p_field, p_temp_c, p_g_rest, p_phi);
	LAFieldHydrosphereSeed::seed(p_field, air, p_g_rest);
	PackedFloat32Array share = air.get("pore_share", PackedFloat32Array());
	if (air.is_empty()) {
		share.resize(p_field ? int(p_field->get("_cell_count")) : 0);
		share.fill(0.0f);
	}
	return compress(p_field, p_g_rest, p_t_rock, share);
}

Dictionary LAFieldLithostaticSeed::shape_atmosphere(Object *p_field, double p_temp_c,
		const PackedFloat32Array &p_g_rest, const PackedFloat64Array &p_phi) {
	Dictionary air;
	if (!p_field) return air;
	const PackedFloat32Array p_gravity = vertical(p_field, p_g_rest);
	Object *grid = Object::cast_to<Object>(p_field->get("_grid"));
	const int cc = int(p_field->get("_cell_count"));
	const PackedByteArray solid = p_field->get("_solid");
	if (!grid || cc <= 0 || solid.size() != cc) return air;
	if (p_gravity.size() != cc * 3) {
		UtilityFunctions::push_error("LAFieldLithostaticSeed.shape_atmosphere: the solved gravity is absent, "
				"so the atmosphere has no scale height and would fill the box to its top at one density.");
		return air;
	}
	const PackedInt32Array nbr = grid->get("neighbours");
	const PackedInt32Array slot_off = grid->get("slot_off");
	const PackedVector3Array centres = grid->get("centres");
	const PackedFloat32Array edges = grid->call("cell_edges");
	if (nbr.is_empty() || slot_off.size() < cc * 7 || p_phi.size() < cc || centres.size() < cc
			|| edges.size() < cc) {
		UtilityFunctions::push_error("LAFieldLithostaticSeed.shape_atmosphere: no face list or no solved "
				"potential, so the atmosphere has nothing to stand its pressure on.");
		return air;
	}
	bool pulled = false;
	for (int c = 0; c < cc && !pulled; c++) {
		const Vector3 g(p_gravity[c * 3], p_gravity[c * 3 + 1], p_gravity[c * 3 + 2]);
		pulled = g.length() > 0.0;
	}
	// A WORLD NOTHING PULLS ON HAS NO COLUMN TO STAND. Below the gravity rung the solve never ran, so
	// there is no vertical and no profile to lay.
	if (!pulled) return air;
	// THE ATMOSPHERE IS THE BODY'S OWN, declared as a mass like its hydrosphere: the N2 inventory, and
	// every other gas in the prebiotic mole ratio to it. The box never decides how much air there is.
	const Dictionary body = LABodySeeds::of("planet");
	const double n2_kg = double(body.get("atmosphere_n2_kg", 0.0));
	const double body_kg = double(body.get("mass_kg", 0.0));
	const double r_sea = double(p_field->call("sea_radius"));
	if (!(n2_kg > 0.0) || !(body_kg > 0.0)) {
		UtilityFunctions::push_error("LAFieldLithostaticSeed.shape_atmosphere: the body record declares no "
				"atmosphere_n2_kg or no mass_kg, so the planet would seed airless.");
		return air;
	}
	if (!(r_sea > 0.0)) {
		UtilityFunctions::push_error("LAFieldLithostaticSeed.shape_atmosphere: the terrain states no sea "
				"radius, so the barometric law has no datum.");
		return air;
	}
	std::vector<Mirror> gases = channel_mirrors(p_field, "phase", "gas");
	const Dictionary table = LASubstances::table();
	const Dictionary x = seeded_air_mole_fractions();
	const double n2_mol = n2_kg / la_physical("MOLAR_MASS_N2_KG_MOL");
	const double x_n2 = double(x.get("n2", 0.0));
	if (!(x_n2 > 0.0)) {
		UtilityFunctions::push_error("LAFieldLithostaticSeed.shape_atmosphere: the seeded air holds no N2, so "
				"the N2 inventory states no amount of any other gas.");
		return air;
	}
	std::vector<double> moles(gases.size(), 0.0);
	std::vector<double> molar(gases.size(), 0.0);
	double mol_sum = 0.0, kg_sum = 0.0;
	for (size_t i = 0; i < gases.size(); i++) {
		const Mirror &m = gases[i];
		molar[i] = double(Dictionary(table.get(m.substance, Dictionary())).get("molar_mass", 0.0));
		moles[i] = n2_mol * double(x.get(m.name, 0.0)) / x_n2;
		mol_sum += moles[i];
		kg_sum += moles[i] * molar[i];
	}
	if (!(mol_sum > 0.0) || !(kg_sum > 0.0)) {
		UtilityFunctions::push_error("LAFieldLithostaticSeed.shape_atmosphere: no gas channel carries the "
				"declared inventory, so the air has no molar mass and no scale height.");
		return air;
	}
	// R T / M of the air, m^2/s^2: the scale height times the gravity it was taken at, one number for the
	// whole body however g varies over it.
	const double rt_over_m = la_physical("GAS_CONSTANT_J_MOL_K") * (p_temp_c + la_physical("KELVIN_OFFSET"))
			/ (kg_sum / mol_sum);
	// THE ROOM A CELL OFFERS THE AIR: the space its rock and sea leave, and the pores of its rock the water
	// table leaves dry. The same fractions the chords read.
	// LA_APPROX: chord_quadrature_lattice
	const PackedFloat32Array rock = p_field->get("_rock_fraction");
	const PackedFloat32Array water = p_field->get("_water_fraction");
	const PackedFloat32Array porosity = LAFieldMirrors::of(p_field, "porosity");
	const PackedFloat32Array sat = LAFieldHydrosphereSeed::saturated_share(p_field);
	const PackedFloat32Array t_rock = p_field->get("_t_rock");
	if (rock.size() != cc || water.size() != cc || porosity.size() != cc || sat.size() != cc
			|| t_rock.size() != cc) {
		UtilityFunctions::push_error("LAFieldLithostaticSeed.shape_atmosphere: no rock, sea, porosity, water "
				"table or rock temperature per cell, so the air has no room to stand in.");
		return air;
	}
	auto open_room = [&](int c) { return 1.0 - double(rock[c]) - double(water[c]); };
	auto dry_pores = [&](int c) { return double(porosity[c]) * std::max(double(rock[c]) - double(sat[c]), 0.0); };
	// AIR IS WHAT THE OUTSIDE REACHES, which is CONNECTIVITY and not a direction: flooded through the
	// faces of every cell with room for it, from every open cell the box edge touches, and laid in an open
	// cell's room and in the dry pores of any. A void the flood never reaches is sealed under rock -- a
	// cavity, not a column, and the barometric law has nothing to say about it.
	std::vector<char> sky(cc, 0);
	std::vector<int> front;
	for (int c = 0; c < cc; c++) {
		if (solid[c] != 0) {
			continue;
		}
		for (int f2 = slot_off[c * 7]; f2 < slot_off[c * 7 + 6]; f2++) {
			if (nbr[f2] < 0) {
				sky[c] = 1;
				front.push_back(c);
				break;
			}
		}
	}
	while (!front.empty()) {
		const int c = front.back();
		front.pop_back();
		for (int f2 = slot_off[c * 7]; f2 < slot_off[c * 7 + 6]; f2++) {
			const int n = nbr[f2];
			if (n < 0 || n >= cc || sky[n] != 0
					|| (solid[n] != 0 && !(open_room(n) > 0.0) && !(dry_pores(n) > 0.0))) {
				continue;
			}
			sky[n] = 1;
			front.push_back(n);
		}
	}
	// THE EXACT ISOTHERMAL HYDROSTATIC SOLUTION, IN THE POTENTIAL THE SOLVE PRODUCED. dp/dz = -rho g
	// with p = rho R T / M integrates to p = p0 exp(-M (phi - phi0) / (R T)) in ANY field, so the
	// profile is a function of the POTENTIAL and not of a height times a local scale height.
	// THE DATUM IS SEA LEVEL, in this field's own potential: every cell straddling the sea radius states
	// it there along its own g, so a slab and the planet anchor the same law at the same place.
	const Vector3 centre = field_centre(p_field);
	double phi_0 = 0.0;
	int at_sea = 0;
	for (int c = 0; c < cc; c++) {
		if (!std::isfinite(double(p_phi[c]))) {
			continue;
		}
		const double r_c = double((centres[c] - centre).length());
		const double e = double(edges[c]);
		if (std::abs(r_c - r_sea) > 0.5 * e) {
			continue;
		}
		const Vector3 g(p_gravity[c * 3], p_gravity[c * 3 + 1], p_gravity[c * 3 + 2]);
		phi_0 += double(p_phi[c]) + double(g.length()) * r_c * r_c * (1.0 / r_c - 1.0 / r_sea);
		at_sea++;
	}
	if (at_sea == 0) {
		UtilityFunctions::push_error("LAFieldLithostaticSeed.shape_atmosphere: no cell straddles the sea "
				"radius, so the barometric law has no datum in this box.");
		return air;
	}
	phi_0 /= double(at_sea);
	// THE DENSITY AT THE DATUM IS THE INVENTORY OVER THE SHELL THE LAW FILLS: n0 = N / (4 pi r_sea^2 H),
	// H the radial integral of the profile in the body's own 1/r potential, from the datum to the EXOBASE:
	// where a molecule's mean free path reaches the scale height, the gas stops being a fluid and the
	// column ends. In a 1/r potential the isothermal integrand does not vanish, so nothing else bounds it.
	const double gm = la_physical("GRAVITATIONAL_CONSTANT") * body_kg;
	const double eps32 = double(std::numeric_limits<float>::epsilon());
	const double sigma = std::sqrt(2.0) * Math::PI * la_physical("N2_KINETIC_DIAMETER_M")
			* la_physical("N2_KINETIC_DIAMETER_M");
	const double avogadro = la_physical("AVOGADRO_PER_MOL");
	const double area = 4.0 * Math::PI * r_sea * r_sea;
	const double h_sea = rt_over_m * r_sea * r_sea / gm;
	// The midpoint shell integral, halved until it holds to float precision.
	auto shell_to = [&](double r_top) -> double {
		if (!(r_top > r_sea)) {
			return NAN;
		}
		int n = int(std::ceil((r_top - r_sea) / h_sea));
		double prev = -1.0;
		for (int it = 0; it < 40; it++) {
			const double h = (r_top - r_sea) / double(n);
			double sum = 0.0;
			for (int i = 0; i < n; i++) {
				const double r = r_sea + (double(i) + 0.5) * h;
				sum += std::exp(-(gm / r_sea - gm / r) / rt_over_m) * (r / r_sea) * (r / r_sea) * h;
			}
			if (prev > 0.0 && std::abs(sum - prev) <= eps32 * sum) {
				return sum;
			}
			prev = sum;
			n *= 2;
		}
		return NAN;
	};
	// lambda(r) = 1 / (sigma n(r)) against H(r) = (R T / M) r^2 / G M, in logs so neither side overflows.
	auto exobase_of = [&](double n0_mol) -> double {
		auto excess = [&](double r) {
			return std::log(n0_mol * avogadro) - (gm / r_sea - gm / r) / rt_over_m
					+ std::log(sigma * rt_over_m * r * r / gm);
		};
		double lo = r_sea, hi = r_sea + h_sea, step = h_sea;
		for (int i = 0; i < 200 && excess(hi) > 0.0; i++) {
			lo = hi;
			step *= 2.0;
			hi += step;
		}
		if (excess(hi) > 0.0 || excess(lo) < 0.0) {
			return NAN;
		}
		for (int i = 0; i < 200; i++) {
			const double mid = 0.5 * (lo + hi);
			if (excess(mid) > 0.0) {
				lo = mid;
			} else {
				hi = mid;
			}
		}
		return 0.5 * (lo + hi);
	};
	// The exobase stands on the datum density and the datum density on the shell under it: one fixed point.
	double shell = 0.0;
	{
		double n0 = mol_sum / (area * h_sea);
		double r_exo = 0.0;
		bool settled = false;
		for (int it = 0; it < 12 && !settled; it++) {
			const double r_next = exobase_of(n0);
			const double s = std::isfinite(r_next) ? shell_to(r_next) : NAN;
			if (!std::isfinite(s) || !(s > 0.0)) {
				break;
			}
			settled = r_exo > 0.0 && std::abs(r_next - r_exo) <= eps32 * r_next;
			r_exo = r_next;
			shell = s;
			n0 = mol_sum / (area * s);
		}
		if (!settled) {
			UtilityFunctions::push_error("LAFieldLithostaticSeed.shape_atmosphere: the barometric column "
					"reached no exobase, so the datum density has no shell to stand on.");
			return air;
		}
	}
	const double kelvin = la_physical("KELVIN_OFFSET");
	std::vector<double> shape(cc, 0.0), in_pores(cc, 0.0);
	auto air_of = [&](int c) -> double {
		const Vector3 g(p_gravity[c * 3], p_gravity[c * 3 + 1], p_gravity[c * 3 + 2]);
		const double gmag = double(g.length());
		const double f = std::max(double(rock[c]), 0.0);
		const double taken = f + std::max(double(water[c]), 0.0);
		const double room = std::max(1.0 - taken, 0.0);
		const double dry = dry_pores(c);
		if (!(gmag > 0.0) || (!(room > 0.0) && !(dry > 0.0))) {
			return 0.0;
		}
		const CubeColumn col = cube_column(double(edges[c]), Vector3(-g / float(gmag)));
		// The level that leaves `p_share` of the cube below it: rock, sea and table settled under this
		// same gravity.
		auto level = [&](double p_share) -> double {
			if (!(p_share > 0.0)) {
				return 0.0;
			}
			double lo = 0.0, hi = col.span;
			for (int i = 0; i < 60; i++) {
				const double mid = 0.5 * (lo + hi);
				if (column_below(col, mid) < p_share) {
					lo = mid;
				} else {
					hi = mid;
				}
			}
			return 0.5 * (lo + hi);
		};
		const double r_c = double((centres[c] - centre).length());
		auto above = [&](double p_share) {
			return cell_air_share(col, level(p_share), double(p_phi[c]), phi_0, gmag, r_c, rt_over_m);
		};
		const double over_ground = above(taken);
		double out = room > 0.0 && solid[c] == 0 ? over_ground : 0.0;
		// THE DRY PORES HOLD THE SAME AIR, in the rock between the table and the ground at its porosity; in
		// rock with no free surface it stands at the rock's own temperature, the density that same pressure
		// has there.
		if (dry > 0.0) {
			const double over_rock = taken > f ? above(f) : over_ground;
			const double t_gas = f < 1.0 ? p_temp_c : double(t_rock[c]);
			in_pores[c] = double(porosity[c]) * (above(double(sat[c])) - over_rock) * (p_temp_c + kelvin)
					/ (t_gas + kelvin);
			out += in_pores[c];
		}
		return out;
	};
	la_parallel_for(cc, [&](int c) {
		if (sky[c] != 0 && std::isfinite(double(p_phi[c]))) {
			shape[c] = air_of(c);
		}
	});
	for (int c = 0; c < cc; c++) {
		if (std::isnan(shape[c])) {
			UtilityFunctions::push_error("LAFieldLithostaticSeed.shape_atmosphere: no Gauss-Legendre count "
					"holds a cell's barometric integral to float precision under its error bound.");
			return air;
		}
	}
	for (size_t i = 0; i < gases.size(); i++) {
		Mirror &m = gases[i];
		const double n0 = moles[i] / (area * shell);
		float *w = m.arr.ptrw();
		for (int c = 0; c < cc; c++) {
			w[c] = float(n0 * shape[c]);
		}
	}
	// ABOVE THE EXOBASE THERE IS NO FLUID. Where the barometric law leaves so little gas that a molecule
	// crosses the whole cell without a collision, the continuum equations say nothing about the cell,
	// and what stands there is the escape law's, not the grid's. The mean free path against the cell:
	// lambda = 1 / (sqrt(2) pi d^2 n).
	{
		const double kn_limit = la_physical("KNUDSEN_CONTINUUM_LIMIT");
		std::vector<double> n_m3(cc, 0.0);
		for (const Mirror &m : gases) {
			for (int c = 0; c < cc; c++) {
				n_m3[c] += std::max(double(m.arr[c]), 0.0) * avogadro;
			}
		}
		for (Mirror &m : gases) {
			float *w = m.arr.ptrw();
			for (int c = 0; c < cc; c++) {
				const double e = double(edges[c]);
				const bool collisionless = !(n_m3[c] > 0.0) || 1.0 / (sigma * n_m3[c]) > e * kn_limit;
				if (collisionless) {
					w[c] = 0.0f;
				}
			}
			LAFieldMirrors::store(p_field, m.name, m.arr);
		}
	}
	// The law it was laid by, for the water that stands under it: p = p_0 exp(-(phi - phi_0) / (R T / M)).
	air["phi_0"] = phi_0;
	air["p_0"] = mol_sum / (area * shell) * la_physical("GAS_CONSTANT_J_MOL_K") * (p_temp_c + kelvin);
	air["rt_over_m"] = rt_over_m;
	// The share of each cell's air that stands in its dry pores, which scales with its porosity.
	PackedFloat32Array pore_share;
	pore_share.resize(cc);
	float *ps = pore_share.ptrw();
	for (int c = 0; c < cc; c++) {
		ps[c] = shape[c] > 0.0 ? float(in_pores[c] / shape[c]) : 0.0f;
	}
	air["pore_share"] = pore_share;
	return air;
}

// THE SEEDED AIR'S COMPOSITION, mole fraction per gas channel. One declaration, read by the lattice
// before there is a field and by shape_atmosphere once there is. A gas that is a photochemical STEADY
// STATE rather than an inventory is absent here and starts at nothing.
Dictionary LAFieldLithostaticSeed::seeded_air_mole_fractions() {
	static const char *const SEEDED[] = { "n2", "co2", "h2", nullptr };
	Dictionary out;
	for (int k = 0; SEEDED[k]; k++) {
		const CharString key = (String("PREBIOTIC_MOLE_FRAC_") + String(SEEDED[k]).to_upper()).utf8();
		out[String(SEEDED[k])] = la_physical(key.get_data());
	}
	return out;
}

// R T / M of that mixture, m^2/s^2: the scale height times the gravity it was taken at.
double LAFieldLithostaticSeed::seeded_air_rt_over_m(double p_temp_c) {
	const Dictionary x = seeded_air_mole_fractions();
	const Dictionary table = LASubstances::table();
	const Array names = x.keys();
	double mol = 0.0, kg = 0.0;
	for (int i = 0; i < names.size(); i++) {
		const double n = double(x[names[i]]);
		mol += n;
		kg += n * double(Dictionary(table.get(names[i], Dictionary())).get("molar_mass", 0.0));
	}
	if (!(mol > 0.0) || !(kg > 0.0)) {
		return NAN;
	}
	return la_physical("GAS_CONSTANT_J_MOL_K") * (p_temp_c + la_physical("KELVIN_OFFSET")) / (kg / mol);
}

// THE TOP OF THE AIR, metres over the datum: where the barometric profile leaves so little gas that a
// molecule crosses a cell of p_cell_edge_m uncollided. Past it there is no fluid, and nothing a grid
// resolves. The same Knudsen cut shape_atmosphere applies cell by cell.
double LAFieldLithostaticSeed::air_extent_m(const String &p_body_key, double p_radius_m,
		double p_temp_c, double p_cell_edge_m) {
	const Dictionary body = LABodySeeds::of(p_body_key);
	const double n2_kg = double(body.get("atmosphere_n2_kg", 0.0));
	const double body_kg = double(body.get("mass_kg", 0.0));
	const double rt_m = seeded_air_rt_over_m(p_temp_c);
	const double x_n2 = double(seeded_air_mole_fractions().get("n2", 0.0));
	if (!(n2_kg > 0.0) || !(body_kg > 0.0) || !(p_radius_m > 0.0) || !(p_cell_edge_m > 0.0)
			|| !(x_n2 > 0.0) || !std::isfinite(rt_m)) {
		return NAN;
	}
	const double g = la_physical("GRAVITATIONAL_CONSTANT") * body_kg / (p_radius_m * p_radius_m);
	const double h = rt_m / g;
	const double mol = n2_kg / la_physical("MOLAR_MASS_N2_KG_MOL") / x_n2;
	const double area = 4.0 * Math::PI * p_radius_m * p_radius_m;
	const double n0 = mol * la_physical("AVOGADRO_PER_MOL") / (area * h);
	const double d = la_physical("N2_KINETIC_DIAMETER_M");
	const double sigma = std::sqrt(2.0) * Math::PI * d * d;
	const double n_kn = 1.0 / (sigma * p_cell_edge_m * la_physical("KNUDSEN_CONTINUUM_LIMIT"));
	return n0 > n_kn ? h * std::log(n0 / n_kn) : 0.0;
}

void LAFieldLithostaticSeed::_bind_methods() {
	ClassDB::bind_static_method("LAFieldLithostaticSeed", D_METHOD("seeded_air_mole_fractions"),
			&LAFieldLithostaticSeed::seeded_air_mole_fractions);
	ClassDB::bind_static_method("LAFieldLithostaticSeed", D_METHOD("seeded_air_rt_over_m", "temp_c"),
			&LAFieldLithostaticSeed::seeded_air_rt_over_m);
	ClassDB::bind_static_method("LAFieldLithostaticSeed",
			D_METHOD("air_extent_m", "body_key", "radius_m", "temp_c", "cell_edge_m"),
			&LAFieldLithostaticSeed::air_extent_m);
	ClassDB::bind_static_method("LAFieldLithostaticSeed", D_METHOD("vertical", "field", "gravity"),
			&LAFieldLithostaticSeed::vertical);
	ClassDB::bind_static_method("LAFieldLithostaticSeed", D_METHOD("compress", "field", "g_rest", "t_rock", "pore_air"),
			&LAFieldLithostaticSeed::compress, DEFVAL(PackedFloat32Array()));
	ClassDB::bind_static_method("LAFieldLithostaticSeed",
			D_METHOD("settle", "field", "temp_c", "g_rest", "phi", "t_rock"), &LAFieldLithostaticSeed::settle);
	ClassDB::bind_static_method("LAFieldLithostaticSeed",
			D_METHOD("shape_atmosphere", "field", "temp_c", "g_rest", "phi"),
			&LAFieldLithostaticSeed::shape_atmosphere);
}
