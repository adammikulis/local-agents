#pragma once

#include <cstdint>
#include <vector>

namespace lasim {

// A UNIFORM BOX OF CUBES and the face list neighbours.glsli walks. Slot order is march.glsli's:
// 0 -x, 1 +x, 2 -y, 3 +y, 4 -z, 5 +z. Every cell owns six faces, so slot_off is dense and a face's
// partner is the neighbour's face on the reverse slot. Gravity in these tests points along -y, so
// vert_up is the +y neighbour.
struct Lattice {
	uint32_t nx = 0;
	uint32_t ny = 0;
	uint32_t nz = 0;
	float edge_m = 0.0f;

	std::vector<int32_t> nbr;        // per face, the cell across it; -1 at the box edge
	std::vector<int32_t> partner;    // per face, the face pointing back; -1 at the box edge
	std::vector<uint32_t> slot_off;  // 7 per cell
	std::vector<float> cell_edge;    // m
	std::vector<float> pos;          // cell*3, m, cell centres
	std::vector<int32_t> vert_up;    // the +y neighbour, -1 where none
	std::vector<int32_t> vert_down;  // the -y neighbour, -1 where none

	static Lattice box(uint32_t nx, uint32_t ny, uint32_t nz, float edge_m, float ox, float oy,
			float oz);

	uint32_t cells() const { return nx * ny * nz; }
	uint32_t faces() const { return cells() * 6u; }
	uint32_t index(uint32_t x, uint32_t y, uint32_t z) const { return (x * ny + y) * nz + z; }
	// The cell one step along slot d, or -1 past the box.
	int32_t step(uint32_t c, uint32_t d) const { return nbr[c * 6u + d]; }
};

} // namespace lasim
