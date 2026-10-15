#ifndef LA_SUBSTANCE_OPTICS_HPP
#define LA_SUBSTANCE_OPTICS_HPP

#include <godot_cpp/variant/dictionary.hpp>

// How each substance that states its optics refracts, scatters and absorbs light.
namespace la_optics {

// Writes each gas's refractivity and King factor into its LASubstances row, and liquid water's refractive
// index, absorption and scattering into water's.
void declare(godot::Dictionary &p_table);

} // namespace la_optics

#endif // LA_SUBSTANCE_OPTICS_HPP
