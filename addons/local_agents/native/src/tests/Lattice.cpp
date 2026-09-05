#include "Lattice.hpp"

namespace lasim {

Lattice Lattice::box(uint32_t nx, uint32_t ny, uint32_t nz, float edge_m, float ox, float oy,
		float oz) {
	Lattice L;
	L.nx = nx;
	L.ny = ny;
	L.nz = nz;
	L.edge_m = edge_m;
	const uint32_t n = nx * ny * nz;
	L.nbr.assign(n * 6u, -1);
	L.partner.assign(n * 6u, -1);
	L.slot_off.assign(n * 7u, 0u);
	L.cell_edge.assign(n, edge_m);
	L.pos.assign(size_t(n) * 3u, 0.0f);
	L.vert_up.assign(n, -1);
	L.vert_down.assign(n, -1);

	for (uint32_t c = 0; c < n; ++c) {
		for (uint32_t d = 0; d < 7u; ++d) { L.slot_off[c * 7u + d] = c * 6u + d; }
	}
	const int32_t dx[6] = { -1, 1, 0, 0, 0, 0 };
	const int32_t dy[6] = { 0, 0, -1, 1, 0, 0 };
	const int32_t dz[6] = { 0, 0, 0, 0, -1, 1 };
	for (uint32_t x = 0; x < nx; ++x) {
		for (uint32_t y = 0; y < ny; ++y) {
			for (uint32_t z = 0; z < nz; ++z) {
				const uint32_t c = L.index(x, y, z);
				L.pos[c * 3u] = ox + (float(x) + 0.5f) * edge_m;
				L.pos[c * 3u + 1u] = oy + (float(y) + 0.5f) * edge_m;
				L.pos[c * 3u + 2u] = oz + (float(z) + 0.5f) * edge_m;
				for (uint32_t d = 0; d < 6u; ++d) {
					const int64_t X = int64_t(x) + dx[d];
					const int64_t Y = int64_t(y) + dy[d];
					const int64_t Z = int64_t(z) + dz[d];
					if (X < 0 || Y < 0 || Z < 0 || X >= nx || Y >= ny || Z >= nz) { continue; }
					const uint32_t nb = L.index(uint32_t(X), uint32_t(Y), uint32_t(Z));
					L.nbr[c * 6u + d] = int32_t(nb);
					L.partner[c * 6u + d] = int32_t(nb * 6u + (d ^ 1u));
				}
				L.vert_up[c] = L.nbr[c * 6u + 3u];
				L.vert_down[c] = L.nbr[c * 6u + 2u];
			}
		}
	}
	return L;
}

} // namespace lasim
