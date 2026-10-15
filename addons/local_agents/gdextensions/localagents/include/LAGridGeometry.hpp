#ifndef LOCAL_AGENTS_LA_GRID_GEOMETRY_HPP
#define LOCAL_AGENTS_LA_GRID_GEOMETRY_HPP

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/vector3.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/vector3i.hpp>

namespace godot {

// PER-CELL GEOMETRY OF THE GRADED GRID. A base lattice of cubes, each an octree of leaves keyed by a
// full-depth Morton code; neighbours differ by at most one level (2:1), so a face joins one cell to one
// or to four. Every entry is a walk over the leaves, which is serial work with no branch worth an
// interpreter.
class LAGridGeometry : public RefCounted {
	GDCLASS(LAGridGeometry, RefCounted);

public:
	// Deepest level a leaf may reach: the Morton code holds 3 bits per level in 32.
	static const int MAX_LEVEL = 10;

	// Edge in metres and volume in m^3 per cell, over interior plus ghost tail.
	static Vector3 radial_box_exit(const Vector3 &p_direction, const Vector3 &p_half_extents);
	static PackedFloat32Array edges(Object *p_grid);
	static PackedFloat32Array volumes(Object *p_grid);
	// Cells at each refinement level, coarsest first.
	static PackedInt32Array level_counts(Object *p_grid);
	// The leaves and face list of a base lattice of p_dims cells with the base cells p_mask marks split
	// once into eight: cell_count, max_level, levels, cell_base, cell_local, cell_morton, base_head,
	// base_leaves, slot_off, neighbours, partners.
	static Dictionary build(const Vector3i &p_dims, const PackedByteArray &p_mask);
	// The same, GRADED BY DISTANCE: a leaf splits while its edge exceeds p_target_edge_m, its centre
	// stands within p_cells_per_level of its own edges of the terrain surface, and -- for a box off the
	// body centre -- within that many of its own edges of the box's radial axis. Bounded by the
	// p_below_m / p_above_m the caller models. The box edge stays coarsest. 2:1 balanced.
	// p_focus_min/max with p_focus_edge_m > 0 name a box refined to that edge whatever the rest says.
	static Dictionary build_graded(const Vector3i &p_dims, const Vector3 &p_origin, double p_cell_size,
			const Vector3 &p_centre, Object *p_terrain, double p_below_m, double p_above_m,
			double p_target_edge_m, double p_cells_per_level, const Vector3 &p_focus_min,
			const Vector3 &p_focus_max, double p_focus_edge_m);
	// build_graded at p_target_edge_m, coarsening the target by two until the leaf count fits p_budget;
	// a grid that never fits stays uniform. Adds target_edge_m to the result.
	static Dictionary build_to_budget(const Vector3i &p_dims, const Vector3 &p_origin, double p_cell_size,
			const Vector3 &p_centre, Object *p_terrain, double p_below_m, double p_above_m,
			double p_target_edge_m, double p_cells_per_level, int p_budget, const Vector3 &p_focus_min,
			const Vector3 &p_focus_max, double p_focus_edge_m);
	// Edge a cell in the air column should have, m: the scale height R_air T / g of a body of p_mass_kg
	// and p_radius_m, over the cells it is cut into.
	static double target_edge_m(double p_mass_kg, double p_radius_m, double p_t_c, double p_cells_per_h);
	// A slice box spec "ox,oy,oz,nx,ny,nz,cell_m,fine_m": offset, dims, cell_size, fine_size,
	// surface_axis and levels, or a single "error" naming what the spec does not describe.
	static Dictionary parse_slice_spec(const String &p_spec);
	// The number docs/CELL_BUDGET declares; -1 when it declares none.
	static int cell_budget();
	// THE FIELD'S GRID: build_to_budget under docs/CELL_BUDGET with the capture box (p_focus_spec, a slice
	// spec or empty) resolved to its own edge, cached under the terrain, the box, the extension and the
	// spec. Returns the geometry to adopt.
	static Dictionary refine_field_grid(Object *p_grid, Object *p_terrain, const Vector3 &p_centre,
			double p_body_radius, double p_below_m, double p_above_m, double p_target_edge_m,
			double p_cells_per_level, const String &p_focus_spec, const String &p_cache_key);
	// Reciprocity, the 2:1 volume ratio and the tiling of every coarse face by the four fine ones.
	static Dictionary validate(Object *p_grid);
	// Centre of every cell in world coordinates, over interior plus ghost tail.
	static PackedVector3Array centres(Object *p_grid);
	static PackedFloat64Array centres_f64(Object *p_grid);
	// The leaf across the box on slot d's axis: the torus partner of c. Box-edge cells are unrefined.
	static int wrap_partner(Object *p_grid, int p_c, int p_d);
	// Centre-to-centre distance across face p_f of cell p_c, m; a box edge has half a cell beyond it.
	static double face_distance(Object *p_grid, int p_c, int p_f);
	// The leaf holding a world point, -1 outside the box.
	static int cell_at(Object *p_grid, const Vector3 &p_point);
	// The face rows of `p_n` ghost cells appended past the interior: six shut faces each, level 0.
	static Dictionary ghost_rows(Object *p_grid, int p_n);
	// Sum of `arr` weighted by each cell's own volume; `mask_open` restricts it to cells where solid is 0.
	static double weighted(const PackedFloat32Array &p_arr, const PackedFloat32Array &p_vol,
			const PackedByteArray &p_solid, bool p_mask_open);

protected:
	static void _bind_methods();
};

} // namespace godot

#endif // LOCAL_AGENTS_LA_GRID_GEOMETRY_HPP
