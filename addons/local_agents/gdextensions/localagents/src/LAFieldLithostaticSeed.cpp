#include "LAFieldLithostaticSeed.hpp"

#include "LAFieldMirrors.hpp"

#include "LABodySystem.hpp"
#include "LAFieldCellMass.hpp"
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
#include <numeric>
#include <thread>
#include <vector>

using namespace godot;

namespace {

const char *CHANNELS_GD = "res://addons/local_agents/sim/material/Channels.gd";
const char *GEOMETRY_GD = "res://addons/local_agents/sim/material/FieldGeometry3D.gd";

// The hydrostatic seed's Gauss-Seidel: over-relaxation factor, sweeps per frozen reconstruction,
// re-takes of it, and the move below which a sweep has settled.

Vector3 field_centre(Object *p_field) {
	Array args;
	args.append(p_field);
	return la_call_gd(GEOMETRY_GD, "centre", args);
}

// p_fn(i) for every i in [0, p_count) across the host's cores, claimed in chunks off one counter.
// p_fn writes only index i's own slots.
template <typename F>
void for_each_index_parallel(int p_count, const F &p_fn) {
	const int workers = int(MAX(std::thread::hardware_concurrency(), 1u));
	const int chunk = 16;
	std::atomic<int> next(0);
	auto run = [&]() {
		for (int lo = next.fetch_add(chunk); lo < p_count; lo = next.fetch_add(chunk)) {
			const int hi = MIN(lo + chunk, p_count);
			for (int i = lo; i < hi; i++) {
				p_fn(i);
			}
		}
	};
	std::vector<std::thread> pool;
	for (int t = 1; t < workers; t++) {
		pool.emplace_back(run);
	}
	run();
	for (std::thread &t : pool) {
		t.join();
	}
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

// Outward unit normal of face slot d. Slot order -X,+X,-Y,+Y,-Z,+Z, as LAVoxelGrid lays it out.
Vector3 slot_normal(int p_d) {
	Vector3 n;
	n[p_d >> 1] = (p_d & 1) ? 1.0 : -1.0;
	return n;
}

// The slot whose step points most nearly along `p_dir`.
int slot_toward(const Vector3 &p_dir) {
	int best = 0;
	double best_dot = -1.0e30;
	for (int d = 0; d < 6; d++) {
		const double dp = p_dir.dot(slot_normal(d));
		if (dp > best_dot) {
			best_dot = dp;
			best = d;
		}
	}
	return best;
}

double eos_p(double vol, double a_gas_rt, double b_vol, double c_comp, double p_ref) {
	if (vol <= 0.0) {
		return 0.0;
	}
	if (c_comp <= 0.0) {
		double room = vol - b_vol;
		return room > 0.0 ? a_gas_rt / room : 0.0;
	}
	// No gas at all: the condensed phases alone are squeezed into the cell.
	if (a_gas_rt <= 0.0) {
		return p_ref + (b_vol - vol) / c_comp;
	}
	double k = vol - b_vol - c_comp * p_ref;
	double disc = sqrt(k * k + 4.0 * c_comp * a_gas_rt);
	// Stable root: (disc - k)/(2C) cancels catastrophically as C -> 0; 2A/(k + disc) is identical.
	double p = (k > 0.0) ? 2.0 * a_gas_rt / (k + disc) : (disc - k) / (2.0 * c_comp);
	return p;
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

Dictionary LAFieldLithostaticSeed::compress(Object *p_field, const PackedFloat32Array &p_gravity,
		const PackedFloat32Array &p_t_rock) {
	PackedFloat32Array out;
	if (!p_field) {
		return Dictionary();
	}
	Object *grid = Object::cast_to<Object>(p_field->get("_grid"));
	const int cc = int(p_field->get("_cell_count"));
	const PackedByteArray solid = p_field->get("_solid");
	if (!grid || cc <= 0 || solid.size() != cc) {
		return Dictionary();
	}
	if (p_gravity.size() != cc * 3) {
		UtilityFunctions::push_error(String("LAFieldLithostaticSeed.compress: the solved gravity is ")
				+ String::num_int64(p_gravity.size()) + " long against " + String::num_int64(cc)
				+ " cells, so the balance has no direction to march along.");
		return Dictionary();
	}
	const Vector3 centre = field_centre(p_field);
	// RESOLUTION FOLLOWS POSITION: a cell's edge and volume are its own.
	const PackedFloat32Array edges = grid->call("cell_edges");
	std::vector<double> dr(cc, 0.0), vol(cc, 0.0);
	for (int c = 0; c < cc && c < edges.size(); c++) {
		dr[c] = double(edges[c]);
		vol[c] = dr[c] * dr[c] * dr[c];
	}
	// A face list the march cannot walk costs it its COLUMN, not the pressure each cell states.
	const PackedInt32Array nbr = grid->get("neighbours");
	const PackedInt32Array slot_off = grid->get("slot_off");
	const bool walkable = !nbr.is_empty() && slot_off.size() >= cc * 7 && edges.size() >= cc;
	const Dictionary table = LASubstances::table();
	const Dictionary rows = la_call_gd(CHANNELS_GD, "rows", Array());
	const double t_c = LABodySeeds::surface_temp_c();
	const double p_std = la_physical("STANDARD_PRESSURE_PA");
	const double rt = la_physical("GAS_CONSTANT_J_MOL_K") * (t_c + la_physical("KELVIN_OFFSET"));

	// Every matter channel, with what the substance table says about the substance it carries.
	std::vector<Mirror> mats = channel_mirrors(p_field, "unit", "mol_m3");
	const size_t nm = mats.size();
	std::vector<double> mm(nm, 0.0), v0(nm, 0.0), v0k(nm, 0.0), rho0(nm, 0.0), psat(nm, 0.0);
	std::vector<double> alpha(nm, 0.0), tref(nm, 0.0);
	std::vector<bool> is_gas(nm, false), is_lithic(nm, false);
	for (size_t i = 0; i < nm; i++) {
		const Dictionary row = rows.get(mats[i].name, Dictionary());
		const Dictionary sub = table.get(mats[i].substance, Dictionary());
		mm[i] = double(sub.get("molar_mass", 0.0));
		is_gas[i] = String(row.get("phase", "")) == "gas";
		is_lithic[i] = bool(row.get("lithic", false)) || bool(row.get("lattice", false));
		alpha[i] = double(sub.get("expansion_per_k", 0.0));
		tref[i] = double(sub.get("density_ref_t_c", 0.0));
		if (is_gas[i]) {
			continue;
		}
		psat[i] = LASubstances::saturation_p_at(mats[i].substance, t_c);
		rho0[i] = LASubstances::density(mats[i].substance, t_c, p_std);
		v0[i] = rho0[i] > 0.0 ? 1.0 / rho0[i] : 0.0;
		const double k = double(sub.get("bulk_modulus_pa", 0.0));
		v0k[i] = k > 0.0 ? v0[i] / k : 0.0;
	}

	// la_eos_p's own coefficients per cell at the amounts the composition laid down, and the mass those
	// amounts weigh. A gas is the A term; a condensed phase is B, and C where it declares a bulk modulus.
	const double rho_tab_h2o = double(Dictionary(table.get("h2o", Dictionary())).get("density", 0.0));
	std::vector<double> a_rt(cc, 0.0), b_vol(cc, 0.0), c_comp(cc, 0.0), rho(cc, 0.0), rho_lith(cc, 0.0);
	for (size_t i = 0; i < nm; i++) {
		const float *r = mats[i].arr.ptr();
		for (int c = 0; c < cc; c++) {
			const double n = r[c] > 0.0f ? double(r[c]) : 0.0;
			if (n <= 0.0) {
				continue;
			}
			rho[c] += n * mm[i];
			rho_lith[c] += is_lithic[i] ? n * mm[i] : 0.0;
			if (is_gas[i]) {
				a_rt[c] += n * vol[c] * rt;
			} else {
				const double kg = n * vol[c] * mm[i];
				// Pore water fills the rock's pores at the table's liquid density, as the derive books it.
				const double kg_pore = mats[i].name == "h2o_pore" ? kg : 0.0;
				// A lithic phase stands at its cell's rock temperature, the derive's lattice volume.
				const double t_here = (is_lithic[i] && c < p_t_rock.size()) ? double(p_t_rock[c]) : t_c;
				const double expand = (1.0 + alpha[i] * (t_here - tref[i])) / (1.0 + alpha[i] * (t_c - tref[i]));
				b_vol[c] += (kg - kg_pore) * v0[i] * expand + (rho_tab_h2o > 0.0 ? kg_pore / rho_tab_h2o : 0.0);
				c_comp[c] += (kg - kg_pore) * v0k[i] * expand;
			}
		}
	}
	// A condensed phase raises its vapour over itself, at its saturation pressure over the room the
	// condensed matter leaves: the same fixed-volume split the derive makes. Water in the rock's pores
	// is the lattice's and raises none into the fluid.
	for (size_t i = 0; i < nm; i++) {
		if (is_gas[i] || !(psat[i] > 0.0) || mats[i].name == "h2o_pore") {
			continue;
		}
		const float *r = mats[i].arr.ptr();
		for (int c = 0; c < cc; c++) {
			const double n = r[c] > 0.0f ? double(r[c]) : 0.0;
			const double room = vol[c] - b_vol[c];
			if (n <= 0.0 || !(room > 0.0)) {
				continue;
			}
			a_rt[c] += MIN(psat[i] * room / rt, n * vol[c]) * rt;
		}
	}

	// kernels3d/pressure.glsl's la_load: the weight per unit area of one cell's matter, Pa, over the
	// step's projection on the local vertical.
	auto column_load = [&](int c) -> double {
		const Vector3 gv(p_gravity[c * 3], p_gravity[c * 3 + 1], p_gravity[c * 3 + 2]);
		const double gm = double(gv.length());
		if (!(gm > 0.0)) {
			return 0.0;
		}
		const Vector3 up = -gv / gm;
		const double m = MAX(MAX(std::abs(up.x), std::abs(up.y)), std::abs(up.z));
		return rho[c] * gm * dr[c] * m;
	};

	// A cell stands at the pressure its own amounts state, off the same equation of state the derive uses.
	std::vector<double> p_at(cc, 0.0);
	PackedFloat32Array p_fluid;
	p_fluid.resize(cc);
	float *pf = p_fluid.ptrw();
	for (int c = 0; c < cc; c++) {
		if (rho[c] > 0.0) {
			p_at[c] = eos_p(vol[c], a_rt[c], b_vol[c], c_comp[c], p_std);
		}
		pf[c] = float(p_at[c]);
	}

	// Height along the local vertical and the slot pointing up it: rock's column marches these.
	const PackedVector3Array la_cw = grid->get("centres");
	std::vector<double> h(cc, 0.0);
	std::vector<int> up_slot(cc, -1);
	for (int c = 0; c < cc; c++) {
		const Vector3 g(p_gravity[c * 3], p_gravity[c * 3 + 1], p_gravity[c * 3 + 2]);
		const double gm = double(g.length());
		if (!(gm > 0.0)) {
			continue;
		}
		const Vector3 up = -g / gm;
		h[c] = double((la_cw[c] - centre).dot(up));
		up_slot[c] = slot_toward(up);
	}
	std::vector<int> order(cc);
	std::iota(order.begin(), order.end(), 0);
	std::sort(order.begin(), order.end(), [&h](int a, int b) { return h[a] > h[b]; });

	// AN OPEN CELL STANDS AT THE PRESSURE ITS OWN MATTER STATES, which `p_at` already holds off the same
	// equation of state the derive uses. Its balance is the composition's to satisfy: the atmosphere is
	// laid along the barometric profile and the hydrosphere into its basins, so the pressures those
	// amounts state are the balanced ones and nothing here writes over them.
	// ROCK IS A COLUMN, and kernels3d/pressure.glsl owns it: the weight standing over the cell, ending at
	// the pressure of the first fluid above. Descending height, so a cell is reached after the one over it.
	for (int c : order) {
		if (!walkable || solid[c] == 0) {
			continue;
		}
		// The cell ABOVE: where the slot meets four finer cells, the one the plumb line runs into.
		// Any other of the four stands over different ground.
		const int d = up_slot[c];
		int u = -1;
		double off = 0.0;
		if (d >= 0) {
			const Vector3 g(p_gravity[c * 3], p_gravity[c * 3 + 1], p_gravity[c * 3 + 2]);
			const double gm = double(g.length());
			const Vector3 up = gm > 0.0 ? Vector3(-g / gm) : Vector3(0, 1, 0);
			const Vector3 here = la_cw[c];
			for (int f2 = slot_off[c * 7 + d]; f2 < slot_off[c * 7 + d + 1]; f2++) {
				const int n = nbr[f2];
				if (n < 0 || n >= cc) {
					continue;
				}
				const Vector3 r = la_cw[n] - here;
				const double lat = double((r - up * float(r.dot(up))).length());
				if (u < 0 || lat < off) {
					u = n;
					off = lat;
				}
			}
		}
		double top = 0.0;
		if (u >= 0 && u < cc) {
			top = solid[u] != 0 ? p_at[u] + 0.5 * column_load(u) : p_at[u];
		}
		p_at[c] = top + 0.5 * column_load(c);
	}
	// THE MATTER IS THE COMPOSITION'S: the radial profile it was laid down from is the hydrostatic
	// solution of the same EOS, so the march states the pressure and moves no mass.
	// The pressure the balance states, so the first state derive is taken at it rather than at zero,
	// and beside it the FLUID's own: what a cell's free matter states, which a locked cell's band and
	// air stand at whatever column its rock carries.
	out.resize(cc);
	float *w = out.ptrw();
	for (int c = 0; c < cc; c++) {
		w[c] = float(p_at[c]);
	}
	// The lattice's pressure: the marched column in a locked cell; in an open cell the fluid's plus half
	// its own rock's weight, the mean over the rock it holds.
	PackedFloat32Array p_rock;
	p_rock.resize(cc);
	float *pr = p_rock.ptrw();
	for (int c = 0; c < cc; c++) {
		const Vector3 gv(p_gravity[c * 3], p_gravity[c * 3 + 1], p_gravity[c * 3 + 2]);
		pr[c] = float(solid[c] != 0 ? p_at[c] : p_at[c] + 0.5 * rho_lith[c] * double(gv.length()) * dr[c]);
	}
	Dictionary both;
	both["pressure"] = out;
	both["fluid"] = p_fluid;
	both["rock"] = p_rock;
	return both;
}

void LAFieldLithostaticSeed::shape_atmosphere(Object *p_field, double p_temp_c,
		const PackedFloat32Array &p_gravity, const PackedFloat64Array &p_phi) {
	if (!p_field) return;
	Object *grid = Object::cast_to<Object>(p_field->get("_grid"));
	const int cc = int(p_field->get("_cell_count"));
	const PackedByteArray solid = p_field->get("_solid");
	if (!grid || cc <= 0 || solid.size() != cc) return;
	if (p_gravity.size() != cc * 3) {
		UtilityFunctions::push_error("LAFieldLithostaticSeed.shape_atmosphere: the solved gravity is absent, "
				"so the atmosphere has no scale height and would fill the box to its top at one density.");
		return;
	}
	const PackedInt32Array nbr = grid->get("neighbours");
	const PackedInt32Array slot_off = grid->get("slot_off");
	const PackedVector3Array centres = grid->get("centres");
	const PackedFloat32Array edges = grid->call("cell_edges");
	if (nbr.is_empty() || slot_off.size() < cc * 7 || p_phi.size() < cc || centres.size() < cc
			|| edges.size() < cc) {
		UtilityFunctions::push_error("LAFieldLithostaticSeed.shape_atmosphere: no face list or no solved "
				"potential, so the atmosphere has nothing to stand its pressure on.");
		return;
	}
	bool pulled = false;
	for (int c = 0; c < cc && !pulled; c++) {
		const Vector3 g(p_gravity[c * 3], p_gravity[c * 3 + 1], p_gravity[c * 3 + 2]);
		pulled = g.length() > 0.0;
	}
	// A WORLD NOTHING PULLS ON HAS NO COLUMN TO STAND. Below the gravity rung the solve never ran, so
	// there is no vertical and no profile to lay.
	if (!pulled) return;
	// THE ATMOSPHERE IS THE BODY'S OWN, declared as a mass like its hydrosphere: the N2 inventory, and
	// every other gas in the prebiotic mole ratio to it. The box never decides how much air there is.
	const Dictionary body = LABodySeeds::of("planet");
	const double n2_kg = double(body.get("atmosphere_n2_kg", 0.0));
	const double body_kg = double(body.get("mass_kg", 0.0));
	const double r_sea = double(p_field->call("sea_radius"));
	if (!(n2_kg > 0.0) || !(body_kg > 0.0)) {
		UtilityFunctions::push_error("LAFieldLithostaticSeed.shape_atmosphere: the body record declares no "
				"atmosphere_n2_kg or no mass_kg, so the planet would seed airless.");
		return;
	}
	if (!(r_sea > 0.0)) {
		UtilityFunctions::push_error("LAFieldLithostaticSeed.shape_atmosphere: the terrain states no sea "
				"radius, so the barometric law has no datum.");
		return;
	}
	std::vector<Mirror> gases = channel_mirrors(p_field, "phase", "gas");
	const Dictionary table = LASubstances::table();
	const Dictionary x = seeded_air_mole_fractions();
	const double n2_mol = n2_kg / la_physical("MOLAR_MASS_N2_KG_MOL");
	const double x_n2 = double(x.get("n2", 0.0));
	std::vector<double> moles(gases.size(), 0.0);
	std::vector<double> molar(gases.size(), 0.0);
	double mol_sum = 0.0, kg_sum = 0.0;
	for (size_t i = 0; i < gases.size(); i++) {
		const Mirror &m = gases[i];
		molar[i] = double(Dictionary(table.get(m.substance, Dictionary())).get("molar_mass", 0.0));
		moles[i] = n2_mol * double(x.get(m.name, 0.0)) / MAX(x_n2, 1.0e-12);
		mol_sum += moles[i];
		kg_sum += moles[i] * molar[i];
	}
	if (!(mol_sum > 0.0) || !(kg_sum > 0.0)) {
		UtilityFunctions::push_error("LAFieldLithostaticSeed.shape_atmosphere: no gas channel carries the "
				"declared inventory, so the air has no molar mass and no scale height.");
		return;
	}
	// R T / M of the air, m^2/s^2: the scale height times the gravity it was taken at, one number for the
	// whole body however g varies over it.
	const double rt_over_m = la_physical("GAS_CONSTANT_J_MOL_K") * (p_temp_c + la_physical("KELVIN_OFFSET"))
			/ (kg_sum / mol_sum);
	// AIR IS WHAT THE OUTSIDE REACHES, which is CONNECTIVITY and not a direction: flooded through open
	// faces from every open cell the box edge touches. A void the flood never reaches is sealed under
	// rock -- a cavity, not a column, and the barometric law has nothing to say about it.
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
			if (n < 0 || n >= cc || solid[n] != 0 || sky[n] != 0) {
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
		return;
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
			return;
		}
	}
	// The air stands in the volume the cell's rock and sea leave, the same fractions the chords read.
	// LA_APPROX: chord_quadrature_lattice
	const PackedFloat32Array rock = p_field->get("_rock_fraction");
	const PackedFloat32Array water = p_field->get("_water_fraction");
	std::vector<double> shape(cc, 0.0);
	auto air_of = [&](int c) -> double {
		const Vector3 g(p_gravity[c * 3], p_gravity[c * 3 + 1], p_gravity[c * 3 + 2]);
		const double gmag = double(g.length());
		const double taken = (c < rock.size() ? std::max(double(rock[c]), 0.0) : 0.0)
				+ (c < water.size() ? std::max(double(water[c]), 0.0) : 0.0);
		const double room = std::max(1.0 - taken, 0.0);
		if (!(gmag > 0.0) || !(room > 0.0)) {
			return 0.0;
		}
		const CubeColumn col = cube_column(double(edges[c]), Vector3(-g / float(gmag)));
		// The level that leaves the rock and the sea below it: they settled under this same gravity.
		double cut = 0.0;
		if (room < 1.0) {
			double lo = 0.0, hi = col.span;
			for (int i = 0; i < 60; i++) {
				const double mid = 0.5 * (lo + hi);
				if (column_below(col, mid) < 1.0 - room) {
					lo = mid;
				} else {
					hi = mid;
				}
			}
			cut = 0.5 * (lo + hi);
		}
		const double r_c = double((centres[c] - centre).length());
		return cell_air_share(col, cut, double(p_phi[c]), phi_0, gmag, r_c, rt_over_m);
	};
	for_each_index_parallel(cc, [&](int c) {
		if (sky[c] != 0 && std::isfinite(double(p_phi[c]))) {
			shape[c] = air_of(c);
		}
	});
	for (int c = 0; c < cc; c++) {
		if (std::isnan(shape[c])) {
			UtilityFunctions::push_error("LAFieldLithostaticSeed.shape_atmosphere: no Gauss-Legendre count "
					"holds a cell's barometric integral to float precision under its error bound.");
			return;
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
	ClassDB::bind_static_method("LAFieldLithostaticSeed", D_METHOD("compress", "field", "gravity", "t_rock"),
			&LAFieldLithostaticSeed::compress);
	ClassDB::bind_static_method("LAFieldLithostaticSeed",
			D_METHOD("shape_atmosphere", "field", "temp_c", "gravity", "phi"),
			&LAFieldLithostaticSeed::shape_atmosphere);
}
