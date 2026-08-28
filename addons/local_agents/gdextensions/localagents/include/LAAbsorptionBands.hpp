#ifndef LOCAL_AGENTS_LA_ABSORPTION_BANDS_HPP
#define LOCAL_AGENTS_LA_ABSORPTION_BANDS_HPP

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>

namespace godot {

// Band-averaged mass absorption coefficients for the absorbing gases, m^2/kg. The data lives in
// LAAbsorptionBands.cpp, emitted by scripts/derive_absorption_bands.py from HITRAN.
class LAAbsorptionBands : public RefCounted {
	GDCLASS(LAAbsorptionBands, RefCounted);

public:
	// Spectral resolution of the absorption table over 0-46000 cm^-1.
	static inline const int BAND_COUNT = 157;
	// Temperature resolution of the coefficient slices, 150-1000 K.
	static inline const int TEMP_COUNT = 9;
	// Sample count of the Planck cumulative table the GPU reads instead of summing the series.
	static inline const int CDF_COUNT = 1024;
	// Upper limit of x = c2*nu/T in that table.
	static inline const float CDF_XMAX = 50.0f;

	// The GPU upload: header, band edges, temperature slices, solar weights, eleven coefficients per
	// (temperature, band), then the Planck cumulative table. flux.glsl's RADIATE row reads it.
	static PackedFloat32Array packed();

protected:
	static void _bind_methods();
};

} // namespace godot

#endif // LOCAL_AGENTS_LA_ABSORPTION_BANDS_HPP
