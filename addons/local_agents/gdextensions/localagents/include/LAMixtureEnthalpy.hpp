#ifndef LOCAL_AGENTS_LA_MIXTURE_ENTHALPY_HPP
#define LOCAL_AGENTS_LA_MIXTURE_ENTHALPY_HPP

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/string.hpp>

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
	static double enthalpy_at(const Dictionary &p_masses, double p_room_m3, double p_t_c, double p_p_pa);
	static PackedFloat64Array breakpoints(const Dictionary &p_masses, double p_p_pa);
	static Dictionary jump_at(const Dictionary &p_masses, double p_room_m3, double p_t_b, double p_p_pa);
	static Dictionary state(const Dictionary &p_masses, double p_room_m3, double p_h_total_j,
			double p_p_pa);
	// Elements one formula may carry on the GPU — enthalpy.glsli LA_MAX_EL.
	static const int MAX_EL = 5;
	// The ladder of one substance as the kernel's props row carries it, THERMAL_ROW_WORDS floats.
	static const int THERMAL_ROW_WORDS = 24 + 4 * MAX_EL;
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
