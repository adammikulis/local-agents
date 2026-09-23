#ifndef LOCAL_AGENTS_LA_MELT_EOS_HPP
#define LOCAL_AGENTS_LA_MELT_EOS_HPP

#include <godot_cpp/variant/dictionary.hpp>

namespace godot {

// The liquid phase of the planet's minerals, as the substance table's melt keys: `density_melt`,
// `density_melt_ref_t_c`, `expansion_melt_per_k`, `bulk_modulus_melt_pa`, `bulk_modulus_melt_deriv`,
// `bulk_modulus_melt_deriv2`. A key the sources do not measure is left off the row.
namespace LAMeltEos {

// A silicate melt from its own stoichiometry by ideal mixing of oxide partial molar volumes. Empty, with a
// named error, for an element the oxide model does not carry or oxygen that does not balance.
Dictionary oxide_melt(const Dictionary &p_formula);
// (Mg,Fe)2SiO4 liquid compression at Mg number `p_mg`: forsterite and fayalite liquids mixed by volume.
Dictionary olivine_melt_compression(double p_mg);
// MgSiO3 liquid compression.
Dictionary enstatite_melt_compression();
// Molten NaCl, measured at its melting point `p_melt_c`.
Dictionary halite_melt(double p_melt_c);

} // namespace LAMeltEos

} // namespace godot

#endif
