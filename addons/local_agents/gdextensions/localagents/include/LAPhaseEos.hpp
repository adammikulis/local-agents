#ifndef LOCAL_AGENTS_LA_PHASE_EOS_HPP
#define LOCAL_AGENTS_LA_PHASE_EOS_HPP

#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string.hpp>

namespace godot {

// One condensed phase as the substance table carries it; rho 0 where it names none. k is isothermal.
struct LAPhaseEos {
	double rho = 0.0;          // kg/m^3 at t_ref_c and one atmosphere
	double t_ref_c = 0.0;
	double alpha = 0.0;        // 1/K at one atmosphere
	double k = 0.0;            // Pa, K_T; 0 where unmeasured
	double kp = 0.0;
	double kpp = 0.0;          // 1/Pa
	bool fourth = false;       // K'' declared: Birch-Murnaghan fourth order
	bool linear_density = false; // the source gives rho, not V, linear in T
	bool kell = false;         // the IAPWS saturated liquid
	double f_lo = 0.0;         // the Eulerian strain bracket where P(f) rises
	double f_hi = 0.0;
};

// A row's solid and liquid, and the one melting rule every consumer reads.
struct LACondensedEos {
	bool valid = false;
	LAPhaseEos solid;
	LAPhaseEos liquid;
	bool melts = false;
	bool iapws = false;
	double melt_c = 0.0;        // solidus at p_ref
	double width = 0.0;         // liquidus - solidus, K
	double p_ref = 0.0;
	double rho_fus_solid = 0.0; // each phase at melt_c and p_ref: the Clapeyron pair
	double rho_fus_liquid = 0.0;
	double slope_k_per_pa = 0.0;
};

// A fluid's Peng-Robinson constants: a(T) = a_c (1 + kappa (1 - sqrt(T/Tc)))^2, b.
struct LAFluidEos {
	bool valid = false;
	double tc_k = 0.0;
	double a_c = 0.0;          // Pa m^6/mol^2
	double b = 0.0;            // m^3/mol
	double kappa = 0.0;
};

namespace LAPhaseEosFn {

const LACondensedEos &condensed(const String &p_id);
const LAFluidEos &fluid(const String &p_id);
bool gas_at(const String &p_id, double p_t_c, double p_p_pa);
double solidus_c(const LACondensedEos &p_c, double p_p_pa);
double melt_fraction(const LACondensedEos &p_c, double p_t_c, double p_p_pa);
// Specific volume of one phase, m^3/kg; 0 where the phase or its state is not measured.
double phase_volume(const LAPhaseEos &p_e, double p_t_c, double p_p_pa);
double phase_k_t(const LAPhaseEos &p_e, double p_p_pa);
// The mixed condensed state, lever-ruled across the melting interval. 0 where a phase present is unmeasured.
double condensed_volume(const LACondensedEos &p_c, double p_t_c, double p_p_pa);
// True where every phase present at (T, p) has a Birch-Murnaghan form that reaches p.
bool representable(const LACondensedEos &p_c, double p_t_c, double p_p_pa);
double condensed_alpha(const LACondensedEos &p_c, double p_t_c, double p_p_pa);
// -dV/dP of the phases at fixed melt fraction, m^3/(kg Pa).
double condensed_compressibility(const LACondensedEos &p_c, double p_t_c, double p_p_pa);
double pr_a(const LAFluidEos &p_f, double p_t_k);
// Molar volume of the fluid at (T, p), m^3/mol: the largest root of the cubic.
double pr_molar_volume(const LAFluidEos &p_f, double p_t_k, double p_p_pa);
// A cell's pressure, kernels3d/eos.glsli la_eos_p's twin: its gas n R T with the Peng-Robinson mixture
// sums s_a = sum n_i sqrt(a_i(T)) and s_b = sum n_i b_i over the room its condensed volume B, squeezed at
// compressibility C about p_ref, leaves.
double mixture_pressure(double vol, double a_gas_rt, double s_a, double s_b, double b_vol, double c_comp,
		double p_ref);
// The rule as data: "solid", "liquid" and "fluid", each empty where the row names none.
Dictionary describe(const String &p_id);

} // namespace LAPhaseEosFn

} // namespace godot

#endif
