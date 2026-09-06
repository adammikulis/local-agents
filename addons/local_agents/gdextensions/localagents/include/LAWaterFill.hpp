#ifndef LOCAL_AGENTS_LA_WATER_FILL_HPP
#define LOCAL_AGENTS_LA_WATER_FILL_HPP

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/vector3.hpp>

namespace godot {

// WHERE THE BODY'S WATER STANDS, from the crust's own shape and nothing else. The inventory falls evenly
// over the surface, runs downhill into the basin each node drains to, and each basin fills until it
// overtops the lowest saddle out of it, at which point the two basins are one body of water. A connected
// body at one level is an ocean; a basin that never overtopped is a lake at its own level. There is no
// declared sea and no single radius: `level_m` is what the fill left.
// Priority-flood watershed labelling: Barnes, Lehman & Mulla 2014, Computers & Geosciences 62:117.
class LAWaterFill : public RefCounted {
	GDCLASS(LAWaterFill, RefCounted);

public:
	// `p_elev_m` is the crust's elevation over the body's mean radius on an equirectangular lattice, row
	// 0 the north pole; `p_water_m3` the inventory. Returns {"level_m": per node, the water SURFACE
	// elevation, NaN where the node is dry; "nlat"; "nlon"; "wet_nodes"; "bodies"; "deepest_m"}.
	static Dictionary solve(const PackedFloat32Array &p_elev_m, int p_nlat, int p_nlon,
			double p_body_r_m, double p_water_m3);
	// The lattice direction of node (i, j) and the reverse: what a consumer reads a level at.
	static Vector3 node_dir(int p_i, int p_j, int p_nlat, int p_nlon);
	// The water surface elevation over `p_dir`, m over the body's mean radius; NaN where the four nodes
	// around the direction are all dry. LA_APPROX: water_level_lattice
	static double level_at(const PackedFloat32Array &p_level_m, int p_nlat, int p_nlon, const Vector3 &p_dir);

protected:
	static void _bind_methods();
};

} // namespace godot

#endif // LOCAL_AGENTS_LA_WATER_FILL_HPP
