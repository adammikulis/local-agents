#ifndef LOCAL_AGENTS_LA_ACOUSTIC_SOLVE_HPP
#define LOCAL_AGENTS_LA_ACOUSTIC_SOLVE_HPP

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/classes/rendering_device.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/rid.hpp>

namespace godot {

// THE STEP'S ACOUSTIC PRESSURE, CONVERGED. One Helmholtz per field step over the same finite-volume
// face graph the gravity solve relaxes: the cell's own acoustic compliance on the diagonal, the face
// conductance the flux predictor wrote off it, solved by Jacobi-preconditioned conjugate gradient.
// Serial work in memory order, one CSR walk per iteration.
class LAAcousticSolve : public RefCounted {
	GDCLASS(LAAcousticSolve, RefCounted);

public:
	// p_slot_off the 7-per-cell face ranges and p_nbr the face list, p_comp kg/Pa per interior cell,
	// p_cond m per face, p_rhs kg per interior cell, p_p the warm start and the output. A neighbour
	// past the interior is vacuum's Dirichlet zero. Returns {"p", "residual_rel", "iterations"}.
	static Dictionary solve(const PackedInt32Array &p_slot_off, const PackedInt32Array &p_nbr,
			const PackedFloat32Array &p_comp, const PackedFloat32Array &p_cond,
			const PackedFloat32Array &p_rhs, const PackedFloat32Array &p_p, double p_dt_s,
			double p_tol_rel, int p_max_iter);

	// solve() over the device's own buffers, writing the converged pressure back into p_p.
	static Dictionary solve_device(RenderingDevice *p_rd, const RID &p_slot_off, const RID &p_nbr,
			int p_cell_count, const RID &p_comp, const RID &p_cond, const RID &p_rhs, const RID &p_p,
			double p_dt_s, double p_tol_rel, int p_max_iter);

protected:
	static void _bind_methods();
};

} // namespace godot

#endif // LOCAL_AGENTS_LA_ACOUSTIC_SOLVE_HPP
