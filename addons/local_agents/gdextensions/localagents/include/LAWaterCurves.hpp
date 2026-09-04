#ifndef LA_WATER_CURVES_HPP
#define LA_WATER_CURVES_HPP

#include <godot_cpp/variant/dictionary.hpp>

// Water's three phase boundaries as the IAPWS formulations state them, each read from either end.
// GPU twin: kernels3d/enthalpy.glsli, held equal by scripts/check_enthalpy_ssot.sh.
namespace la_water {

// Writes the coefficients of all three equations into water's LASubstances row, so a kernel copy of one
// binds to the table rather than to a second literal.
void declare_iapws(godot::Dictionary &p_row);

double iapws_saturation_p_pa(double p_t_k);
double iapws_saturation_dln_dt(double p_t_k);
double iapws_saturation_t_k(double p_p_pa);
double iapws_sublimation_p_pa(double p_t_k);
double iapws_sublimation_dln_dt(double p_t_k);
double iapws_sublimation_t_k(double p_p_pa);
double iapws_melting_ih_p_pa(double p_t_k);
double iapws_melting_ih_t_k(double p_p_pa);
double iapws_melting_ih_pa_per_k(double p_t_k);

} // namespace la_water

#endif // LA_WATER_CURVES_HPP
