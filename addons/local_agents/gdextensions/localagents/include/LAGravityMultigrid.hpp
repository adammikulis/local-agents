#ifndef LOCAL_AGENTS_LA_GRAVITY_MULTIGRID_HPP
#define LOCAL_AGENTS_LA_GRAVITY_MULTIGRID_HPP

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/classes/rendering_device.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/rid.hpp>

#include <vector>

namespace godot {

// GEOMETRIC MULTIGRID FOR THE GRAVITY POTENTIAL. One octree extended above the base lattice: level 0 is
// the leaf grid, level L the same tree cut at one depth coarser, and past the base lattice the cells
// agglomerate 2:1 until the coarsest lattice is a few cells a side. build() is the geometry, once per
// grid; cycle() drives V-cycles on the device through gravity_multigrid.glsl.
class LAGravityMultigrid : public RefCounted {
	GDCLASS(LAGravityMultigrid, RefCounted);

public:
	// Cells a side the coarsest lattice may still hold, and the depth field the flag word carries.
	static const int COARSEST_SPAN = 4;
	static const int DEPTH_MAX = 31;

	// The hierarchy for p_grid, its device tables, and the uniform set gravity_multigrid.glsl reads
	// them through, over the driver's own buffers in p_bufs. Idempotent: the second call is a no-op.
	bool attach(RenderingDevice *p_rd, const RID &p_shader, Object *p_grid, const Dictionary &p_bufs);

	// The pass's own pre-solve dispatch, V-cycles until the discrete residual over its own source falls
	// below p_tol_rel or p_max_cycles are spent, then its post-solve dispatch. Returns {"residual_rel",
	// "cycles", "factor"}: factor is the residual's geometric mean fall per cycle, 1 when none ran.
	Dictionary solve(RenderingDevice *p_rd, Object *p_pass, const RID &p_pipe, int p_cc, int p_groups,
			double p_g_si, double p_tol_rel, int p_max_cycles);

	// Frees the hierarchy's buffers and its uniform set.
	void dispose(RenderingDevice *p_rd);

protected:
	static void _bind_methods();

private:
	Dictionary cycle(RenderingDevice *p_rd, const RID &p_pipe, double p_g_si, double p_tol_rel,
			int p_max_cycles);

	RID set_;
	RID moments_;
	std::vector<RID> owned_;
	PackedInt32Array level_off_;
	int levels_ = 0;
	double coarse_edge_ = 0.0;
};

} // namespace godot

#endif // LOCAL_AGENTS_LA_GRAVITY_MULTIGRID_HPP
