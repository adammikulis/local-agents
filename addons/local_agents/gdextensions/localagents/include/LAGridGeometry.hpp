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
	static PackedFloat32Array edges(Object *p_grid);
	static PackedFloat32Array volumes(Object *p_grid);
	// The leaves and face list of a base lattice of p_dims cells with the base cells p_mask marks split
	// once into eight: cell_count, max_level, levels, cell_base, cell_local, cell_morton, base_head,
	// base_leaves, slot_off, neighbours, partners.
	static Dictionary build(const Vector3i &p_dims, const PackedByteArray &p_mask);
	// The same, refined where resolution is owed: a leaf splits while its edge exceeds p_target_edge_m
	// and its cube reaches within p_below_m / p_above_m of the terrain surface. The box edge stays
	// coarsest. 2:1 balanced.
	static Dictionary build_graded(const Vector3i &p_dims, const Vector3 &p_origin, double p_cell_size,
			const Vector3 &p_centre, Object *p_terrain, double p_below_m, double p_above_m,
			double p_target_edge_m);
	// build_graded at p_target_edge_m, coarsening the target by two until the leaf count fits p_budget;
	// a grid that never fits stays uniform. Adds target_edge_m to the result.
	static Dictionary build_to_budget(const Vector3i &p_dims, const Vector3 &p_origin, double p_cell_size,
			const Vector3 &p_centre, Object *p_terrain, double p_below_m, double p_above_m,
			double p_target_edge_m, int p_budget);
	// Edge a cell in the air column should have, m: the scale height R_air T / g of a body of p_mass_kg
	// and p_radius_m, over the cells it is cut into.
	static double target_edge_m(double p_mass_kg, double p_radius_m, double p_t_c, double p_cells_per_h);
	// The number docs/CELL_BUDGET declares; -1 when it declares none.
	static int cell_budget();
	// Reciprocity, the 2:1 volume ratio and the tiling of every coarse face by the four fine ones.
	static Dictionary validate(Object *p_grid);
	// Centre of every cell in world coordinates, over interior plus ghost tail.
	static PackedVector3Array centres(Object *p_grid);
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
