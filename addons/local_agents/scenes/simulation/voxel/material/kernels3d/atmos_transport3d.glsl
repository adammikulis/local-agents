#[compute]
#version 450

// GPU 3D atmosphere TRANSPORT — a race-free GATHER port of MaterialAtmosphere3D._transport(). The CPU
// oracle is a SCATTER that accumulates three effects into `_adelta` (all reading the SAME old snapshot,
// applied once at the end):
//   1) 6-neighbour isotropic DIFFUSION (forward +X/+Z/+Y pairs; the back neighbour gets the opposite
//      flux, so it is symmetric & order-independent), weight = diffuse_frac * DIFF6 (DIFF6 = 1/6).
//   2) buoyant RISE — a share `rise_frac` of a cell's matter is convected straight UP into the open cell
//      above (humid air rises to the cool heights where it condenses).
//   3) horizontal WIND — first-order upwind advection by the LOCAL PER-CELL wind velocity (from the
//      emergent MaterialWind3D field): a cell sends a share `ax`/`az` of its matter to its single downwind
//      neighbour, where ax = clamp(|vel_x| * wdt, 0, 0.5) and wdt = wind_gain * step_dt / cell_size (and
//      similarly az from vel_z). This REPLACES the old single global scalar wind, so moisture funnels
//      through valleys and piles up where the local wind converges (fronts). Each cell reads its OWN
//      vel_x/vel_z (and neighbours read theirs), so the gather sums: LOSE my downwind share + GAIN each
//      neighbour's share aimed at me.
// Matter only ever moves between NON-SOLID cells (rock is a wall to air, exactly like water). The gather
// form computes, for each cell, the NET of these three reading only the old snapshot, so it reproduces
// the scatter's Jacobi result exactly. The caller runs this kernel three times (vapor / cloud / fog) with
// per-field diffuse_frac, rise_frac and wind_gain (folded into wdt). Constants + math copied EXACTLY from
// MaterialAtmosphere3D.gd — do not diverge.
//
// Index layout: idx = (iy*dim_z + iz)*dim_x + ix.

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer QIn { float q_in[]; };
layout(set = 0, binding = 1, std430) restrict readonly buffer Solid { float solid[]; };
layout(set = 0, binding = 2, std430) restrict writeonly buffer QOut { float q_out[]; };
layout(set = 0, binding = 3, std430) restrict readonly buffer VelX { float vel_x[]; };
layout(set = 0, binding = 4, std430) restrict readonly buffer VelZ { float vel_z[]; };

layout(push_constant, std430) uniform Params {
	uint dim_x;
	uint dim_y;
	uint dim_z;
	uint cell_count;
	float diffuse_frac;   // isotropic spread per step
	float rise_frac;      // buoyant upward share (0 for fog)
	float wdt;            // wind_gain * step_dt / cell_size (per-cell ax = clamp(|vel_x|*wdt, 0, 0.5))
	float pad0;
} params;

const float DIFF6 = 1.0 / 6.0;

void main() {
	uint g = gl_GlobalInvocationID.x;
	if (g >= params.cell_count) {
		return;
	}
	int dim_x = int(params.dim_x);
	int dim_y = int(params.dim_y);
	int dim_z = int(params.dim_z);
	int layer = dim_x * dim_z;
	int idx = int(g);
	int iy = idx / layer;
	int rem_i = idx - iy * layer;
	int iz = rem_i / dim_x;
	int ix = rem_i - iz * dim_x;

	// Solid cells are walls to air: their value is carried through unchanged (matches the CPU apply loop
	// which skips solid cells).
	if (solid[g] != 0.0) {
		q_out[g] = q_in[g];
		return;
	}

	float q = q_in[g];
	float d = params.diffuse_frac * DIFF6;
	float delta = 0.0;

	// 1) DIFFUSION — gather D*(q_n - q) from every in-bounds NON-SOLID neighbour (the symmetric Laplacian
	// equivalent of the CPU forward-pair scatter).
	if (ix > 0)          { int n = idx - 1;     if (solid[n] == 0.0) { delta += d * (q_in[n] - q); } }
	if (ix < dim_x - 1)  { int n = idx + 1;     if (solid[n] == 0.0) { delta += d * (q_in[n] - q); } }
	if (iz > 0)          { int n = idx - dim_x; if (solid[n] == 0.0) { delta += d * (q_in[n] - q); } }
	if (iz < dim_z - 1)  { int n = idx + dim_x; if (solid[n] == 0.0) { delta += d * (q_in[n] - q); } }
	if (iy > 0)          { int n = idx - layer; if (solid[n] == 0.0) { delta += d * (q_in[n] - q); } }
	if (iy < dim_y - 1)  { int n = idx + layer; if (solid[n] == 0.0) { delta += d * (q_in[n] - q); } }

	// 2) BUOYANT RISE — lose rise_frac up into an open cell above; gain the rise_frac the open cell below
	// convected up into me.
	if (params.rise_frac > 0.0) {
		if (iy < dim_y - 1) {
			int iu = idx + layer;
			if (solid[iu] == 0.0 && q > 0.0) { delta -= q * params.rise_frac; }
		}
		if (iy > 0) {
			int ib = idx - layer;
			if (solid[ib] == 0.0) { float qb = q_in[ib]; if (qb > 0.0) { delta += qb * params.rise_frac; } }
		}
	}

	// 3) HORIZONTAL WIND — first-order upwind advection by the LOCAL per-cell velocity. wdt folds in
	// wind_gain*step_dt/cell_size; the CPU scatter skips q3<=0 (a cell with no matter sends nothing) — in
	// this gather that falls out because q_in[neighbour] == 0 contributes 0.
	float wdt = params.wdt;
	if (wdt > 0.0) {
		// --- X axis: LOSE my downwind share ---
		float vx = vel_x[g];
		float axi = clamp(abs(vx) * wdt, 0.0, 0.5);
		if (axi > 0.0 && q > 0.0) {
			int sx = vx > 0.0 ? 1 : -1;
			int nxi = ix + sx;
			if (nxi >= 0 && nxi < dim_x) { int n = idx + sx; if (solid[n] == 0.0) { delta -= q * axi; } }
		}
		// GAIN from the left neighbour if IT blows +x toward me.
		if (ix > 0) {
			int m = idx - 1;
			if (solid[m] == 0.0) { float vm = vel_x[m]; if (vm > 0.0) { delta += q_in[m] * clamp(vm * wdt, 0.0, 0.5); } }
		}
		// GAIN from the right neighbour if IT blows -x toward me.
		if (ix < dim_x - 1) {
			int m = idx + 1;
			if (solid[m] == 0.0) { float vm = vel_x[m]; if (vm < 0.0) { delta += q_in[m] * clamp(-vm * wdt, 0.0, 0.5); } }
		}
		// --- Z axis: LOSE my downwind share ---
		float vz = vel_z[g];
		float azi = clamp(abs(vz) * wdt, 0.0, 0.5);
		if (azi > 0.0 && q > 0.0) {
			int sz = vz > 0.0 ? 1 : -1;
			int nzi = iz + sz;
			if (nzi >= 0 && nzi < dim_z) { int n = idx + sz * dim_x; if (solid[n] == 0.0) { delta -= q * azi; } }
		}
		// GAIN from the -z neighbour if IT blows +z toward me.
		if (iz > 0) {
			int m = idx - dim_x;
			if (solid[m] == 0.0) { float vm = vel_z[m]; if (vm > 0.0) { delta += q_in[m] * clamp(vm * wdt, 0.0, 0.5); } }
		}
		// GAIN from the +z neighbour if IT blows -z toward me.
		if (iz < dim_z - 1) {
			int m = idx + dim_x;
			if (solid[m] == 0.0) { float vm = vel_z[m]; if (vm < 0.0) { delta += q_in[m] * clamp(-vm * wdt, 0.0, 0.5); } }
		}
	}

	float v = q + delta;
	q_out[g] = v > 0.0 ? v : 0.0;
}
