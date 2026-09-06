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


// A leaf: its level, and its integer coordinates at that level. Level 0 is the coarse box; level 1 is
// the half at x < nx/2, split once.
namespace {

struct Leaf {
	uint32_t level = 0;
	uint32_t x = 0, y = 0, z = 0;
};

} // namespace

Lattice Lattice::graded_x(uint32_t nx, uint32_t ny, uint32_t nz, float edge_m, float ox, float oy,
		float oz) {
	Lattice L;
	L.nx = nx;
	L.ny = ny;
	L.nz = nz;
	L.edge_m = edge_m;
	const uint32_t hx = nx / 2u;
	const uint32_t fx = hx * 2u, fy = ny * 2u, fz = nz * 2u;
	std::vector<Leaf> leaf;
	std::vector<int32_t> fine_at(size_t(fx) * fy * fz, -1);
	std::vector<int32_t> coarse_at(size_t(nx) * ny * nz, -1);
	auto fidx = [&](uint32_t x, uint32_t y, uint32_t z) { return (size_t(x) * fy + y) * fz + z; };
	auto cidx = [&](uint32_t x, uint32_t y, uint32_t z) { return (size_t(x) * ny + y) * nz + z; };
	for (uint32_t x = 0; x < fx; ++x) {
		for (uint32_t y = 0; y < fy; ++y) {
			for (uint32_t z = 0; z < fz; ++z) {
				fine_at[fidx(x, y, z)] = int32_t(leaf.size());
				leaf.push_back({ 1u, x, y, z });
			}
		}
	}
	for (uint32_t x = hx; x < nx; ++x) {
		for (uint32_t y = 0; y < ny; ++y) {
			for (uint32_t z = 0; z < nz; ++z) {
				coarse_at[cidx(x, y, z)] = int32_t(leaf.size());
				leaf.push_back({ 0u, x, y, z });
			}
		}
	}
	const uint32_t n = uint32_t(leaf.size());
	L.leaves = n;
	L.cell_edge.assign(n, edge_m);
	L.pos.assign(size_t(n) * 3u, 0.0f);
	L.vert_up.assign(n, -1);
	L.vert_down.assign(n, -1);
	for (uint32_t c = 0; c < n; ++c) {
		const Leaf &l = leaf[c];
		const float e = l.level == 0u ? edge_m : 0.5f * edge_m;
		L.cell_edge[c] = e;
		L.pos[c * 3u] = ox + (float(l.x) + 0.5f) * e;
		L.pos[c * 3u + 1u] = oy + (float(l.y) + 0.5f) * e;
		L.pos[c * 3u + 2u] = oz + (float(l.z) + 0.5f) * e;
	}

	// The cells across each slot, in slot order, so the face list is dense per cell.
	const int32_t dx[6] = { -1, 1, 0, 0, 0, 0 };
	const int32_t dy[6] = { 0, 0, -1, 1, 0, 0 };
	const int32_t dz[6] = { 0, 0, 0, 0, -1, 1 };
	std::vector<std::vector<int32_t>> across(size_t(n) * 6u);
	for (uint32_t c = 0; c < n; ++c) {
		const Leaf &l = leaf[c];
		for (uint32_t d = 0; d < 6u; ++d) {
			const int64_t X = int64_t(l.x) + dx[d], Y = int64_t(l.y) + dy[d], Z = int64_t(l.z) + dz[d];
			if (X < 0 || Y < 0 || Z < 0) { continue; }
			if (l.level == 1u) {
				if (Y >= fy || Z >= fz) { continue; }
				if (X < int64_t(fx)) {
					across[c * 6u + d].push_back(fine_at[fidx(uint32_t(X), uint32_t(Y), uint32_t(Z))]);
				} else if (X == int64_t(fx) && hx < nx) {
					across[c * 6u + d].push_back(
							coarse_at[cidx(hx, uint32_t(Y) / 2u, uint32_t(Z) / 2u)]);
				}
				continue;
			}
			if (Y >= int64_t(ny) || Z >= int64_t(nz) || X >= int64_t(nx)) { continue; }
			if (X < int64_t(hx)) {
				// FOUR FINE CELLS ACROSS ONE COARSE FACE: the 2:1 seam this lattice exists for.
				for (uint32_t a = 0; a < 2u; ++a) {
					for (uint32_t b = 0; b < 2u; ++b) {
						across[c * 6u + d].push_back(
								fine_at[fidx(fx - 1u, l.y * 2u + a, l.z * 2u + b)]);
					}
				}
			} else {
				across[c * 6u + d].push_back(coarse_at[cidx(uint32_t(X), uint32_t(Y), uint32_t(Z))]);
			}
		}
	}

	L.slot_off.assign(size_t(n) * 7u, 0u);
	uint32_t f = 0;
	for (uint32_t c = 0; c < n; ++c) {
		for (uint32_t d = 0; d < 6u; ++d) {
			L.slot_off[c * 7u + d] = f;
			f += uint32_t(across[c * 6u + d].size());
		}
		L.slot_off[c * 7u + 6u] = f;
	}
	L.nbr.assign(f, -1);
	L.partner.assign(f, -1);
	for (uint32_t c = 0; c < n; ++c) {
		uint32_t at = L.slot_off[c * 7u];
		for (uint32_t d = 0; d < 6u; ++d) {
			for (int32_t nb : across[c * 6u + d]) { L.nbr[at++] = nb; }
		}
	}
	// The face pointing back: the one on the neighbour's reverse slot whose own neighbour is this cell.
	for (uint32_t c = 0; c < n; ++c) {
		for (uint32_t face = L.slot_off[c * 7u]; face < L.slot_off[c * 7u + 6u]; ++face) {
			const int32_t nb = L.nbr[face];
			if (nb < 0) { continue; }
			uint32_t d = 0;
			while (d < 6u && face >= L.slot_off[c * 7u + d + 1u]) { ++d; }
			const uint32_t rev = d ^ 1u;
			for (uint32_t b = L.slot_off[uint32_t(nb) * 7u + rev];
					b < L.slot_off[uint32_t(nb) * 7u + rev + 1u]; ++b) {
				if (L.nbr[b] == int32_t(c)) {
					L.partner[face] = int32_t(b);
					break;
				}
			}
		}
	}
	for (uint32_t c = 0; c < n; ++c) {
		const uint32_t up_lo = L.slot_off[c * 7u + 3u], up_hi = L.slot_off[c * 7u + 4u];
		const uint32_t dn_lo = L.slot_off[c * 7u + 2u], dn_hi = L.slot_off[c * 7u + 3u];
		L.vert_up[c] = up_hi > up_lo ? L.nbr[up_lo] : -1;
		L.vert_down[c] = dn_hi > dn_lo ? L.nbr[dn_lo] : -1;
	}
	return L;
}

} // namespace lasim
