#[compute]
#version 450

// CUBED-SPHERE atmosphere TRANSPORT — sphere port of atmos_transport3d.glsl (box). Every cross-cell
// gather that the box did by idx arithmetic (±1, ±dim_x, ±layer) + `if(ix>0)` bounds is replaced by the
// precomputed NEIGHBOUR INDEX TABLE `nbr[idx*6 + d]` (slot 0=inward/DOWN, 1=-a, 2=+a, 3=-b, 4=+b lateral,
// 5=outward/UP; -1 = boundary → skipped). The three transported effects and ALL their math are copied
// VERBATIM from the box kernel:
//   1) 6-neighbour isotropic DIFFUSION — gather d*(q_n - q) from every in-table NON-SOLID neighbour
//      (all six slots), d = diffuse_frac * DIFF6 (DIFF6 = 1/6).
//   2) buoyant RISE — lose rise_frac UP into the open OUTWARD cell (slot 5); gain the rise_frac the open
//      INWARD cell (slot 0) convected up into me. (box +layer→slot5, -layer→slot0.)
//   3) horizontal WIND — first-order upwind advection by the LOCAL per-cell wind velocity. The box's two
//      cartesian axes map onto the sphere's two lateral tangent axes: wind X → the a-axis (slot 1=-a,
//      slot 2=+a); wind Z → the b-axis (slot 3=-b, slot 4=+b). A cell LOSES its downwind share to the
//      lateral slot picked by the sign of its own wind component, and GAINS each lateral neighbour's share
//      that is aimed back at it (neighbour blows toward me). ax = clamp(|vel_x|*wdt, 0, 0.5), likewise az.
// Matter only ever moves between NON-SOLID cells (rock is a wall to air). Race-free GATHER (read q_in,
// write q_out), run once per field (vapor / cloud / fog) with per-field diffuse_frac, rise_frac, wdt.

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer QIn { float q_in[]; };
layout(set = 0, binding = 1, std430) restrict readonly buffer Solid { float solid[]; };
layout(set = 0, binding = 2, std430) restrict writeonly buffer QOut { float q_out[]; };
layout(set = 0, binding = 3, std430) restrict readonly buffer VelX { float vel_x[]; };
layout(set = 0, binding = 4, std430) restrict readonly buffer VelZ { float vel_z[]; };
layout(set = 0, binding = 15, std430) restrict readonly buffer Neigh { int nbr[]; };

layout(push_constant, std430) uniform Params {
	uint cell_count;
	float diffuse_frac;   // isotropic spread per step
	float rise_frac;      // buoyant outward (up) share (0 for fog)
	float wdt;            // wind_gain * step_dt / cell_size (per-cell ax = clamp(|vel_x|*wdt, 0, 0.5))
} params;

const float DIFF6 = 1.0 / 6.0;

void main() {
	uint g = gl_GlobalInvocationID.x;
	if (g >= params.cell_count) {
		return;
	}
	int idx = int(g);

	// Solid cells are walls to air: their value is carried through unchanged (matches the CPU apply loop
	// which skips solid cells).
	if (solid[g] != 0.0) {
		q_out[g] = q_in[g];
		return;
	}

	float q = q_in[g];
	float d = params.diffuse_frac * DIFF6;
	float delta = 0.0;

	int base = idx * 6;

	// 1) DIFFUSION — gather d*(q_n - q) from every in-table NON-SOLID neighbour (all 6 slots): the
	// symmetric Laplacian equivalent of the box forward-pair scatter.
	for (int s = 0; s < 6; s++) {
		int nb = nbr[base + s];
		if (nb >= 0 && solid[nb] == 0.0) {
			delta += d * (q_in[nb] - q);
		}
	}

	// 2) BUOYANT RISE — lose rise_frac up into an open OUTWARD cell (slot 5); gain the rise_frac the open
	// INWARD cell (slot 0) convected up into me.
	if (params.rise_frac > 0.0) {
		int iu = nbr[base + 5];
		if (iu >= 0 && solid[iu] == 0.0 && q > 0.0) {
			delta -= q * params.rise_frac;
		}
		int ib = nbr[base + 0];
		if (ib >= 0 && solid[ib] == 0.0) {
			float qb = q_in[ib];
			if (qb > 0.0) {
				delta += qb * params.rise_frac;
			}
		}
	}

	// 3) HORIZONTAL WIND — first-order upwind advection by the LOCAL per-cell velocity. wdt folds in
	// wind_gain*step_dt/cell_size; a cell with no matter sends nothing (q_in==0 contributes 0 in the gather).
	float wdt = params.wdt;
	if (wdt > 0.0) {
		// --- a-axis (wind X): LOSE my downwind share into slot 2 (+a) if vx>0 else slot 1 (-a) ---
		float vx = vel_x[g];
		float axi = clamp(abs(vx) * wdt, 0.0, 0.5);
		if (axi > 0.0 && q > 0.0) {
			int slot = vx > 0.0 ? 2 : 1;
			int n = nbr[base + slot];
			if (n >= 0 && solid[n] == 0.0) {
				delta -= q * axi;
			}
		}
		// GAIN from the -a neighbour (slot 1) if IT blows +a toward me.
		{
			int m = nbr[base + 1];
			if (m >= 0 && solid[m] == 0.0) {
				float vm = vel_x[m];
				if (vm > 0.0) { delta += q_in[m] * clamp(vm * wdt, 0.0, 0.5); }
			}
		}
		// GAIN from the +a neighbour (slot 2) if IT blows -a toward me.
		{
			int m = nbr[base + 2];
			if (m >= 0 && solid[m] == 0.0) {
				float vm = vel_x[m];
				if (vm < 0.0) { delta += q_in[m] * clamp(-vm * wdt, 0.0, 0.5); }
			}
		}
		// --- b-axis (wind Z): LOSE my downwind share into slot 4 (+b) if vz>0 else slot 3 (-b) ---
		float vz = vel_z[g];
		float azi = clamp(abs(vz) * wdt, 0.0, 0.5);
		if (azi > 0.0 && q > 0.0) {
			int slot = vz > 0.0 ? 4 : 3;
			int n = nbr[base + slot];
			if (n >= 0 && solid[n] == 0.0) {
				delta -= q * azi;
			}
		}
		// GAIN from the -b neighbour (slot 3) if IT blows +b toward me.
		{
			int m = nbr[base + 3];
			if (m >= 0 && solid[m] == 0.0) {
				float vm = vel_z[m];
				if (vm > 0.0) { delta += q_in[m] * clamp(vm * wdt, 0.0, 0.5); }
			}
		}
		// GAIN from the +b neighbour (slot 4) if IT blows -b toward me.
		{
			int m = nbr[base + 4];
			if (m >= 0 && solid[m] == 0.0) {
				float vm = vel_z[m];
				if (vm < 0.0) { delta += q_in[m] * clamp(-vm * wdt, 0.0, 0.5); }
			}
		}
	}

	float v = q + delta;
	q_out[g] = v > 0.0 ? v : 0.0;
}
