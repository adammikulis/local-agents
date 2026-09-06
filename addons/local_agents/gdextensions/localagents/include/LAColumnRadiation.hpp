#ifndef LOCAL_AGENTS_LA_COLUMN_RADIATION_HPP
#define LOCAL_AGENTS_LA_COLUMN_RADIATION_HPP

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>

namespace godot {

// ONE COLUMN OF AIR, radiating. The band table LAAbsorptionBands packs and the two-stream march
// flux.glsl's RADIATE row runs, over a single hydrostatic column instead of the grid: what the seed can
// ask before there is a grid to ask it of.
// LA_APPROX: seed_radiative_column
class LAColumnRadiation : public RefCounted {
	GDCLASS(LAColumnRadiation, RefCounted);

public:
	// kg/m^2 of each absorber a well-mixed column presents, in the order flux.glsl's band_tau reads:
	// CO2 line, CO2 CIA, H2O line, H2O continuum, O3 line, O3 cross-section, CH4, CO, SO2, H2S.
	static PackedFloat64Array absorber_paths(const Dictionary &p_air_x, double p_surface_pa,
			double p_g_m_s2);
	// R/cp of the gas mixture: the exponent of its dry adiabat.
	static double adiabat_exponent(const Dictionary &p_air_x);
	// The isothermal top an optically thin grey layer settles at, K.
	static double skin_temp_k(double p_net_in_w_m2);
	// W/m^2 leaving the top of that column with its surface at `p_ts_k`.
	static double outgoing_longwave_w_m2(double p_ts_k, double p_t_skin_k, const Dictionary &p_air_x,
			double p_surface_pa, double p_g_m_s2);
	// The surface temperature, K, whose outgoing longwave equals `p_net_in_w_m2`. NAN if the band table
	// is absent: an unmeasured temperature, never a plausible one.
	static double equilibrium_temp_k(double p_net_in_w_m2, const Dictionary &p_air_x,
			double p_surface_pa, double p_g_m_s2);

protected:
	static void _bind_methods();
};

} // namespace godot

#endif // LOCAL_AGENTS_LA_COLUMN_RADIATION_HPP
