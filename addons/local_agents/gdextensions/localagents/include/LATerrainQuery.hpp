#ifndef LOCAL_AGENTS_LA_TERRAIN_QUERY_HPP
#define LOCAL_AGENTS_LA_TERRAIN_QUERY_HPP

#include <godot_cpp/classes/object.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/vector3i.hpp>

#include <cmath>

namespace godot {

// The terrain generator's signed distance at world points, one graph evaluation each and no ray march:
// VoxelGeneratorGraph.generate_single on the SDF channel, at the nearest metre.
inline PackedFloat32Array la_terrain_sdf(Object *p_terrain, const PackedVector3Array &p_points) {
	PackedFloat32Array out;
	if (!p_terrain) {
		return out;
	}
	Object *gen = Object::cast_to<Object>(p_terrain->get("_generator"));
	if (!gen || !gen->has_method("generate_single")) {
		return out;
	}
	const int sdf_channel = 1;   // VoxelBuffer.CHANNEL_SDF
	out.resize(p_points.size());
	float *w = out.ptrw();
	for (int i = 0; i < p_points.size(); i++) {
		const Vector3 p = p_points[i];
		const Vector3i q(int(std::lround(p.x)), int(std::lround(p.y)), int(std::lround(p.z)));
		w[i] = float(double(gen->call("generate_single", q, sdf_channel)));
	}
	return out;
}

} // namespace godot

#endif // LOCAL_AGENTS_LA_TERRAIN_QUERY_HPP
