#ifndef LOCAL_AGENTS_LA_MIXTURE_ENTHALPY_HPP
#define LOCAL_AGENTS_LA_MIXTURE_ENTHALPY_HPP

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/string.hpp>

#include "LASubstanceRow.hpp"

namespace godot {

// A CELL IS NOT A SUBSTANCE. Rock, water and air sit in one cell at ONE temperature; LASubstances answers
// per substance and in J/kg. This sums their curves by mass and inverts. `room_m3` is the cell's gas room
// of gas that cannot condense here.
class LAMixtureEnthalpy : public RefCounted {
	GDCLASS(LAMixtureEnthalpy, RefCounted);

public:
	static double vapour_boundary_c(const String &p_id, double p_p_pa);
	static double vapour_p_at(const String &p_id, double p_t_c, double p_p_pa);
	static double vapour_share(const String &p_id, double p_t_c, double p_m_kg, double p_room_m3,
			double p_p_v);
	static double vapour_fraction(const String &p_id, double p_t_c, double p_p_pa, double p_m_kg,
			double p_room_m3);
	static double specific_enthalpy(const String &p_id, double p_t_c, double p_p_pa, double p_m_kg,
			double p_room_m3);
	// The same read for a row a caller already holds, so a walk looks each substance up once.
	static double specific_enthalpy_of(const LASubstanceRow &p_row, double p_t_c, double p_p_pa, double p_m_kg,
			double p_room_m3);
	static double enthalpy_at(const Dictionary &p_masses, double p_room_m3, double p_t_c, double p_p_pa);
	static PackedFloat64Array breakpoints(const Dictionary &p_masses, double p_p_pa);
	static Dictionary jump_at(const Dictionary &p_masses, double p_room_m3, double p_t_b, double p_p_pa);
	static Dictionary state(const Dictionary &p_masses, double p_room_m3, double p_h_total_j,
			double p_p_pa);
	// Elements one formula may carry on the GPU — enthalpy.glsli LA_MAX_EL.
	static const int MAX_EL = 5;
	// The ladder of one substance as the kernel's props row carries it: state_derive.glsl TH_*, held to
	// these by scripts/check_derive_props_layout.sh.
	static constexpr int TH_C_SOL = 0;
	static constexpr int TH_C_LIQ = 1;
	static constexpr int TH_C_GAS = 2;
	static constexpr int TH_LINE_A1 = 3;
	static constexpr int TH_LINE_P0 = 4;
	static constexpr int TH_FUSION_T0 = 5;
	static constexpr int TH_FUSION_T1 = 6;
	static constexpr int TH_VAPOUR_T = 7;
	static constexpr int TH_VAPOUR_P = 8;
	static constexpr int TH_TRIPLE_T = 9;
	static constexpr int TH_TRIPLE_P = 10;
	static constexpr int TH_CRIT_T = 11;
	static constexpr int TH_CRIT_P = 12;
	static constexpr int TH_L_FUS = 13;
	static constexpr int TH_L_VAP = 14;
	static constexpr int TH_L_VAP_T = 15;
	static constexpr int TH_ATOMISATION = 16;
	static constexpr int TH_S_GAS = 17;
	static constexpr int TH_S_ATOMS = 18;
	static constexpr int TH_NU = 19;
	static constexpr int TH_HAS_FUSION = 20;
	static constexpr int TH_HAS_VAPOUR = 21;
	static constexpr int TH_IAPWS = 22;
	static constexpr int TH_N_EL = 23;
	static constexpr int TH_EL_N = 24;
	static constexpr int TH_EL_CHI = 29;
	static constexpr int TH_EL_G0 = 34;
	static constexpr int TH_EL_G1 = 39;
	static constexpr int TH_LINE_KIND = 44;
	static constexpr int TH_LINE_T0 = 45;
	static constexpr int TH_LINE_C1 = 46;
	static constexpr int TH_LINE_A2 = 47;
	static constexpr int TH_LINE_C2 = 48;
	static constexpr int TH_ANCHOR_PHASE = 49;
	static constexpr int TH_ANCHOR_T = 50;
	static constexpr int TH_LINE_PREF = 51;
	static constexpr int TH_PR_KAPPA = 52;
	static const int THERMAL_ROW_WORDS = 53;
	static PackedFloat32Array thermal_row(const String &p_id);
	// J/kg/K of the phase this substance stands in at (t, p) — state_derive.glsl la_phase_c.
	static double phase_specific_heat(const String &p_id, double p_t_c, double p_p_pa);

protected:
	static void _bind_methods();

private:
	static double _solve(const Dictionary &p_masses, double p_room_m3, double p_h_total_j, double p_p_pa,
			double p_lo, double p_hi);
	static Dictionary _pinned(const Dictionary &p_masses, double p_room_m3, double p_t_b, double p_p_pa,
			const Dictionary &p_jump, double p_residual_j);
	static Dictionary _report(const Dictionary &p_masses, double p_room_m3, double p_t_c, double p_p_pa,
			const Dictionary &p_pinned_share, bool p_pinned);
};

} // namespace godot

#endif // LOCAL_AGENTS_LA_MIXTURE_ENTHALPY_HPP
