#ifndef LOCAL_AGENTS_LA_GRAVITY_SOLVE_HPP
#define LOCAL_AGENTS_LA_GRAVITY_SOLVE_HPP

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/classes/rendering_device.hpp>
#include <godot_cpp/variant/rid.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>

namespace godot {

// THE POISSON SOLVE, CONVERGED: the same finite-volume operator gravity_poisson.glsl relaxes, face
// conductance area/dist summed over the face list, solved by Jacobi-preconditioned conjugate gradient
// over the interior with the Dirichlet ring held. Serial work in memory order, one CSR walk per iteration.
class LAGravitySolve : public RefCounted {
	GDCLASS(LAGravitySolve, RefCounted);

public:
	// p_density kg/m^3 per cell, p_phi the DEVIATION from the monopole reference (a warm start; the ring
	// is held at zero), p_flag_bytes the cellflag buffer (bit 0 = ring), p_moments [M, com] off the device. Returns {"phi", "residual_rel",
	// "iterations"}; residual_rel is max |L phi - src| / max |src| over the interior, per unit volume.
	static Dictionary solve(Object *p_grid, const PackedFloat32Array &p_density,
			const PackedFloat32Array &p_phi, const PackedByteArray &p_flag_bytes, double p_g_si,
			double p_tol_rel, int p_max_iter, const PackedFloat32Array &p_moments);

	// solve() over the device's own buffers: reads density, the warm-start deviation, the flags and the
	// moments, writes the converged deviation back into p_phi. Returns {"residual_rel", "iterations"}.
	static Dictionary solve_device(RenderingDevice *p_rd, Object *p_grid, const RID &p_density,
			const RID &p_phi, const RID &p_flags, const RID &p_moments, double p_g_si, double p_tol_rel,
			int p_max_iter);
	// Element-wise a + b: the full potential from the device's deviation and reference.
	static PackedFloat32Array sum(const PackedFloat32Array &p_a, const PackedFloat32Array &p_b);

protected:
	static void _bind_methods();
};

} // namespace godot

#endif // LOCAL_AGENTS_LA_GRAVITY_SOLVE_HPP
