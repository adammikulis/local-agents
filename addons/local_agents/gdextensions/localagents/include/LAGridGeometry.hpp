#ifndef LOCAL_AGENTS_LA_GRID_GEOMETRY_HPP
#define LOCAL_AGENTS_LA_GRID_GEOMETRY_HPP

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/vector3.hpp>
#include <godot_cpp/variant/vector3i.hpp>

namespace godot {

// PER-CELL GEOMETRY OF THE GRADED GRID, and the mask that says where it is fine. Every entry is a walk
// over the cell or base-cell array, which is serial work with no per-cell branch worth an interpreter.
class LAGridGeometry : public RefCounted {
	GDCLASS(LAGridGeometry, RefCounted);

public:
	// Edge in metres and volume in m^3 per cell, over interior plus ghost tail.
	static PackedFloat32Array edges(Object *p_grid);
	static PackedFloat32Array volumes(Object *p_grid);
	// 1 per base cell the grid refines: within `below`/`above` of the terrain surface, and only where a
	// cell is coarser than the air column `above_m` names. The box edge is never marked.
	static PackedByteArray refine_mask(Object *p_grid, const Vector3 &p_centre, Object *p_terrain,
			double p_below_m, double p_above_m);
	// The leaves and the face list of a base lattice of p_dims cells with the base cells p_mask marks
	// split into eight: cell_count, levels, cell_base, cell_oct, base_head, base_split, slot_off,
	// neighbours, partners.
	static Dictionary build(const Vector3i &p_dims, const PackedByteArray &p_mask);
	// Reciprocity, the 2:1 volume ratio and the tiling of every coarse face by the four fine ones.
	static Dictionary validate(Object *p_grid);
	// Centre of every cell in world coordinates, over interior plus ghost tail.
	static PackedVector3Array centres(Object *p_grid);
	// The face rows of `p_n` ghost cells appended past the interior: six shut faces each, level 0.
	// {levels, slot_off, neighbours, partners}, ready to assign back.
	static Dictionary ghost_rows(Object *p_grid, int p_n);
	// Sum of `arr` weighted by each cell's own volume — the matter a channel holds. `mask_open`
	// restricts it to cells where `solid` is 0.
	static double weighted(const PackedFloat32Array &p_arr, const PackedFloat32Array &p_vol,
			const PackedByteArray &p_solid, bool p_mask_open);

protected:
	static void _bind_methods();
};

} // namespace godot

#endif // LOCAL_AGENTS_LA_GRID_GEOMETRY_HPP
