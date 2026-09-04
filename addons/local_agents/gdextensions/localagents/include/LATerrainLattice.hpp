#ifndef LOCAL_AGENTS_LA_TERRAIN_LATTICE_HPP
#define LOCAL_AGENTS_LA_TERRAIN_LATTICE_HPP

#include <godot_cpp/classes/object.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/variant.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/vector3.hpp>
#include <godot_cpp/variant/vector3i.hpp>

#include <cmath>
#include <cstring>
#include <vector>

namespace godot {

// THE TERRAIN'S SIGNED DISTANCE ON A LATTICE, generated in blocks by the voxel generator itself
// (VoxelGenerator.generate_block into a VoxelBuffer, read back as one byte array per block) and read
// by trilinear interpolation. One evaluation per lattice point, batched; no ray march per query.
struct LATerrainLattice {
	Vector3 origin;
	double spacing = 0.0;
	int n = 0;
	std::vector<float> d;

	bool valid() const { return n > 1 && spacing > 0.0 && int(d.size()) == n * n * n; }

	// Lattice points per axis the box is cut into, whatever its size: the lattice is a bounded cost.
	static const int POINTS_PER_AXIS = 256;

	// The lod whose 2^lod metre spacing cuts p_extent into at most POINTS_PER_AXIS points.
	static int lod_for(double p_extent) {
		return std::max(int(std::ceil(std::log2(std::max(p_extent / double(POINTS_PER_AXIS), 1.0)))), 0);
	}

	float at(int x, int y, int z) const { return d[size_t(x) + size_t(n) * (size_t(y) + size_t(n) * size_t(z))]; }

	// Signed distance at a world point, trilinear; clamped to the lattice's extent.
	double sample(const Vector3 &p) const {
		const double fx = std::min(std::max(double(p.x - origin.x) / spacing, 0.0), double(n - 1) - 1e-6);
		const double fy = std::min(std::max(double(p.y - origin.y) / spacing, 0.0), double(n - 1) - 1e-6);
		const double fz = std::min(std::max(double(p.z - origin.z) / spacing, 0.0), double(n - 1) - 1e-6);
		const int x = int(fx), y = int(fy), z = int(fz);
		const double tx = fx - x, ty = fy - y, tz = fz - z;
		auto lerp = [](double a, double b, double t) { return a + (b - a) * t; };
		const double c00 = lerp(at(x, y, z), at(x + 1, y, z), tx);
		const double c10 = lerp(at(x, y + 1, z), at(x + 1, y + 1, z), tx);
		const double c01 = lerp(at(x, y, z + 1), at(x + 1, y, z + 1), tx);
		const double c11 = lerp(at(x, y + 1, z + 1), at(x + 1, y + 1, z + 1), tx);
		return lerp(lerp(c00, c10, ty), lerp(c01, c11, ty), tz);
	}

	// Build over the box [p_origin, p_origin + p_extent] at 2^lod metres, in blocks of p_block^3, only
	// for blocks that can hold the surface: within [p_r_lo, p_r_hi] of p_centre. A block wholly inside
	// reads a negative distance, wholly outside a positive one. The terrain answers
	// `sdf_lattice(origin_m, n, lod)` with the block's SDF channel as float32 bytes. One lattice per box.
	static const LATerrainLattice &build(Object *p_terrain, const Vector3 &p_origin, double p_extent,
			int p_lod, int p_block, const Vector3 &p_centre, double p_r_lo, double p_r_hi) {
		static LATerrainLattice cache;
		static Vector3 cache_origin;
		static double cache_extent = -1.0;
		static int cache_lod = -1;
		if (cache.valid() && cache_origin == p_origin && cache_extent == p_extent && cache_lod == p_lod) {
			return cache;
		}
		cache = build_fresh(p_terrain, p_origin, p_extent, p_lod, p_block, p_centre, p_r_lo, p_r_hi);
		cache_origin = p_origin;
		cache_extent = p_extent;
		cache_lod = p_lod;
		return cache;
	}

	static LATerrainLattice build_fresh(Object *p_terrain, const Vector3 &p_origin, double p_extent,
			int p_lod, int p_block, const Vector3 &p_centre, double p_r_lo, double p_r_hi) {
		LATerrainLattice out;
		if (!p_terrain || p_extent <= 0.0 || p_lod < 0) {
			return out;
		}
		Object *gen = Object::cast_to<Object>(p_terrain->get("_generator"));
		if (!gen || !gen->has_method("generate_block")) {
			return out;
		}
		const int CHANNEL_SDF = 1;   // VoxelBuffer.CHANNEL_SDF
		const int DEPTH_32_BIT = 2;  // VoxelBuffer.DEPTH_32_BIT
		out.spacing = std::ldexp(1.0, p_lod);
		out.n = int(std::ceil(p_extent / out.spacing)) + 2;
		out.origin = p_origin;
		out.d.assign(size_t(out.n) * out.n * out.n, 0.0f);
		int probe_bx = -1, probe_by = -1, probe_bz = -1;
		int generated = 0;
		double probe_spread = 0.0;
		for (int bz = 0; bz < out.n; bz += p_block) {
			for (int by = 0; by < out.n; by += p_block) {
				for (int bx = 0; bx < out.n; bx += p_block) {
					const Vector3 bo = p_origin + Vector3(float(bx), float(by), float(bz)) * float(out.spacing);
					// Radius range this block spans; a block that cannot meet the surface is filled by sign.
					const Vector3 half = Vector3(1, 1, 1) * float(0.5 * p_block * out.spacing);
					const Vector3 mid = bo + half;
					const double r_mid = double((mid - p_centre).length());
					const double r_half = double(half.length());
					if (p_r_lo > 0.0 && r_mid + r_half < p_r_lo) {
						for (int z = 0; z < p_block && bz + z < out.n; z++) for (int y = 0; y < p_block && by + y < out.n; y++) for (int x = 0; x < p_block && bx + x < out.n; x++) {
							out.d[size_t(bx + x) + size_t(out.n) * (size_t(by + y) + size_t(out.n) * size_t(bz + z))] = float(r_mid - p_r_lo);
						}
						continue;
					}
					if (p_r_hi > 0.0 && r_mid - r_half > p_r_hi) {
						for (int z = 0; z < p_block && bz + z < out.n; z++) for (int y = 0; y < p_block && by + y < out.n; y++) for (int x = 0; x < p_block && bx + x < out.n; x++) {
							out.d[size_t(bx + x) + size_t(out.n) * (size_t(by + y) + size_t(out.n) * size_t(bz + z))] = float(r_mid - p_r_hi);
						}
						continue;
					}
					// One generated block: the generator fills a VoxelBuffer, whose SDF channel comes back as bytes.
					Variant vb = ClassDB::instantiate("VoxelBuffer");
					Object *buf = Object::cast_to<Object>(vb);
					if (!buf) {
						out.d.clear();
						out.n = 0;
						return out;
					}
					buf->call("create", p_block, p_block, p_block);
					buf->call("set_channel_depth", CHANNEL_SDF, DEPTH_32_BIT);
					gen->call("generate_block", vb, Vector3i(int(std::lround(bo.x)), int(std::lround(bo.y)), int(std::lround(bo.z))), p_lod);
					const PackedByteArray bytes = buf->call("get_channel_as_byte_array", CHANNEL_SDF);
					if (bytes.size() < p_block * p_block * p_block * 4) {
						out.d.clear();
						out.n = 0;
						return out;
					}
					const float *src = reinterpret_cast<const float *>(bytes.ptr());
					generated++;
					// The layout probe needs a block whose distance VARIES: a transposed index is invisible
					// inside a block that reads one value throughout.
					if (bx + p_block <= out.n && by + p_block <= out.n && bz + p_block <= out.n) {
						const int nv = p_block * p_block * p_block;
						double lo_v = src[0], hi_v = src[0];
						for (int i = 1; i < nv; i++) {
							lo_v = std::min(lo_v, double(src[i]));
							hi_v = std::max(hi_v, double(src[i]));
						}
						if (hi_v - lo_v > probe_spread) {
							probe_spread = hi_v - lo_v;
							probe_bx = bx;
							probe_by = by;
							probe_bz = bz;
						}
					}
					for (int z = 0; z < p_block && bz + z < out.n; z++) {
						for (int y = 0; y < p_block && by + y < out.n; y++) {
							for (int x = 0; x < p_block && bx + x < out.n; x++) {
								// VoxelBuffer stores ZXY: y runs fastest, then x, then z.
								out.d[size_t(bx + x) + size_t(out.n) * (size_t(by + y) + size_t(out.n) * size_t(bz + z))]
										= src[y + p_block * (x + p_block * z)];
							}
						}
					}
				}
			}
		}
		// THE LATTICE IS CHECKED AGAINST THE GENERATOR ON A HALF-BLOCK OFFSET, once per axis: the same
		// distance from the same source through a different index origin, so a transposed layout, a
		// shifted origin or a wrong spacing shows where the two overlap. A slab, not a corner, so the
		// overlap spans the block on the axes it is not offset on. The terrain's own `sdf_at` cannot be
		// the reference: it is a RADIAL depth below the outermost ground, and at a cave wall it reads
		// kilometres of rock where the generator's distance reads the boundary it stands on.
		if (generated > 0 && !(probe_spread > out.spacing)) {
			UtilityFunctions::push_error("LATerrainLattice: no generated block holds a varying distance, so "
					"the layout could not be checked and the lattice is not trusted.");
			out.d.clear();
			out.n = 0;
			return out;
		}
		for (int axis = 0; axis < 3 && probe_bx >= 0; axis++) {
			const int half = p_block / 2;
			int off[3] = { 0, 0, 0 };
			off[axis] = half;
			const Vector3 bo2 = p_origin + Vector3(float(probe_bx + off[0]), float(probe_by + off[1]),
					float(probe_bz + off[2])) * float(out.spacing);
			Variant vb2 = ClassDB::instantiate("VoxelBuffer");
			Object *buf2 = Object::cast_to<Object>(vb2);
			if (!buf2) {
				out.d.clear();
				out.n = 0;
				return out;
			}
			buf2->call("create", p_block, p_block, p_block);
			buf2->call("set_channel_depth", CHANNEL_SDF, DEPTH_32_BIT);
			gen->call("generate_block", vb2, Vector3i(int(std::lround(bo2.x)), int(std::lround(bo2.y)),
					int(std::lround(bo2.z))), p_lod);
			const PackedByteArray b2 = buf2->call("get_channel_as_byte_array", CHANNEL_SDF);
			if (b2.size() < p_block * p_block * p_block * 4) {
				out.d.clear();
				out.n = 0;
				return out;
			}
			const float *s2 = reinterpret_cast<const float *>(b2.ptr());
			const int span[3] = { axis == 0 ? half : p_block, axis == 1 ? half : p_block,
				axis == 2 ? half : p_block };
			for (int z = 0; z < span[2]; z++) {
				for (int y = 0; y < span[1]; y++) {
					for (int x = 0; x < span[0]; x++) {
						const double a = double(out.at(probe_bx + off[0] + x, probe_by + off[1] + y,
								probe_bz + off[2] + z));
						const double b = double(s2[y + p_block * (x + p_block * z)]);
						if (!std::isfinite(a) || !std::isfinite(b)
								|| std::abs(a - b) > 1.0e-3 * std::max(1.0, std::abs(a))) {
							UtilityFunctions::push_error(String("LATerrainLattice: the same generator read through "
									"two index origins disagrees by ") + String::num(std::abs(a - b))
									+ " m (spacing " + String::num(out.spacing)
									+ " m), so the lattice layout is not the terrain's and nothing reads it.");
							out.d.clear();
							out.n = 0;
							return out;
						}
					}
				}
			}
		}
		return out;
	}
};

} // namespace godot

#endif // LOCAL_AGENTS_LA_TERRAIN_LATTICE_HPP
