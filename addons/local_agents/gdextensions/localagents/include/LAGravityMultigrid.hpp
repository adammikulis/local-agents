#ifndef LOCAL_AGENTS_LA_GRAVITY_MULTIGRID_HPP
#define LOCAL_AGENTS_LA_GRAVITY_MULTIGRID_HPP

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/classes/rendering_device.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/rid.hpp>

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

	// The hierarchy as flat device tables: {"total", "level_off", "coarse_edge", "slot_off", "nbr",
	// "flags", "parent", "child_off", "child_idx"}. Empty when the grid has no cells.
	static Dictionary build(Object *p_grid);

	// V-cycles until the discrete residual over its own source falls below p_tol_rel, or p_max_cycles.
	// p_pipe/p_uset are gravity_multigrid.glsl's, p_hier is build()'s dictionary, p_moments the moments
	// buffer whose slot 5 the kernel folds the residual into. Returns {"residual_rel", "cycles",
	// "factor"}: factor is the residual's geometric mean fall per cycle, 1 when no cycle ran.
	static Dictionary cycle(RenderingDevice *p_rd, const RID &p_pipe, const RID &p_uset,
			const RID &p_moments, const Dictionary &p_hier, double p_coarse_edge, double p_g_si,
			double p_tol_rel, int p_max_cycles);

protected:
	static void _bind_methods();
};

} // namespace godot

#endif // LOCAL_AGENTS_LA_GRAVITY_MULTIGRID_HPP
