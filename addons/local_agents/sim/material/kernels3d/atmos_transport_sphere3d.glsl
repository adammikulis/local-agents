#[compute]
#version 450

// CUBED-SPHERE atmosphere TRANSPORT — sphere port of atmos_transport3d.glsl (box). Every cross-cell
// gather that the box did by idx arithmetic (±1, ±dim_x, ±layer) + `if(ix>0)` bounds is replaced by the
// precomputed NEIGHBOUR INDEX TABLE `nbr[idx*6 + d]` (slot 0=inward/DOWN, 1=-a, 2=+a, 3=-b, 4=+b lateral,
// 5=outward/UP; -1 = boundary → skipped). The three transported effects and ALL their math are copied
// VERBATIM from the box kernel:
//   1) 6-neighbour isotropic DIFFUSION — gather d*(q_n - q) from every in-table NON-SOLID neighbour
//      (all six slots), d = diffuse_frac * DIFF6 (DIFF6 = 1/6). Kept WEAK so it doesn't smear cloud masses
//      back into a flat veil — the wind advection below is what builds structure.
//   2) VERTICAL WIND ADVECTION — upwind advect by the LOCAL radial wind vel_y (slot 5 up, slot 0 down),
//      replacing the old constant buoyant `rise_frac`. Updrafts concentrate moisture into cloud masses at
//      convergence; subsidence clears the gaps. Same conservative gather form as the horizontal wind.
//      3) horizontal WIND — first-order upwind advection by the LOCAL per-cell wind velocity. The box's two
//      cartesian axes map onto the CELL'S OWN TANGENT FRAME (vel_x along tan_a, vel_z along tan_b), which is
//      a table of its own — NOT the neighbour slots, which cannot carry a consistently-handed frame on a
//      sphere (see wind_step_sphere3d). So a cell's speed toward a given lateral neighbour is the dot of its
//      velocity with that link's direction in its own frame (`ltan`), and it LOSES a share into every link it
//      is blowing toward and GAINS from every neighbour blowing back at it (read from that neighbour's own
//      reverse link, l ^ 1). In a face interior the four directions are exactly ±a, ±b and this reduces to
//      the old per-axis form: a = clamp(|v·dir|*wdt, 0, 0.3333).
// Matter only ever moves between NON-SOLID cells (rock is a wall to air). Race-free GATHER (read q_in,
// write q_out), run once on the unified `moisture` channel with diffuse_frac, wdt_y (vertical), wdt.

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer QIn { float q_in[]; };
layout(set = 0, binding = 1, std430) restrict readonly buffer Solid { float solid[]; };
layout(set = 0, binding = 2, std430) restrict writeonly buffer QOut { float q_out[]; };
layout(set = 0, binding = 3, std430) restrict readonly buffer VelX { float vel_x[]; };
layout(set = 0, binding = 4, std430) restrict readonly buffer VelZ { float vel_z[]; };
layout(set = 0, binding = 5, std430) restrict readonly buffer VelY { float vel_y[]; };  // OUTWARD-RADIAL (up) wind
layout(set = 0, binding = 15, std430) restrict readonly buffer Neigh { int nbr[]; };
layout(set = 0, binding = 16, std430) restrict readonly buffer LinkTan { float ltan[]; };  // per-column link dirs

layout(push_constant, std430) uniform Params {
	uint cell_count;
	float diffuse_frac;   // isotropic spread per step
	float wdt_y;          // VERTICAL wind gain: vwind_gain * step_dt / cell_size (per-cell ay = clamp(|vel_y|*wdt_y, 0, 0.5))
	float wdt;            // wind_gain * step_dt / cell_size (per-cell ax = clamp(|vel_x|*wdt, 0, 0.5))
	uint depth;           // radial shells per column — turns a cell index into its column for the ltan lookup
	uint pad0;
	uint pad1;
	uint pad2;
} params;

const float DIFF6 = 1.0 / 6.0;
// CFL cap on a cell's total outgoing share (diffusion + advection together), the role OUT_MAX plays in
// dust_outscale_sphere3d.glsl. A cell cannot send more vapour than it holds, so the physical ceiling is 1.0;
// 0.9 keeps a 10% stability margin. A NUMERICAL limit, not a property of water, so not an LAPhysical constant.
const float OUT_MAX = 0.9;

// Speed of cell `c` toward its lateral link `l` (0..3 == neighbour slots 1..4), in that cell's tangent frame.
float toward_link(uint c, int l) {
	uint b = ((c / max(params.depth, 1u)) * 4u + uint(l)) * 2u;
	return vel_x[c] * ltan[b] + vel_z[c] * ltan[b + 1u];
}

// TOTAL ADVECTIVE outgoing share of cell `c` (vertical + the four lateral links), before scaling. Reads ONLY
// c's own velocity and the solid flags of c's neighbours, so c and every neighbour of c compute the SAME
// number — which is what lets the scaled exchange stay conservative to the face without a precomputed buffer.
// Diffusion is deliberately EXCLUDED: it is a symmetric Laplacian that already conserves pairwise, and scaling
// it per-cell would make the two ends of a face disagree, breaking the very thing this function exists to fix.
float raw_adv_out(uint c) {
	uint b = c * 6u;
	float t = 0.0;
	float wdy = params.wdt_y;
	if (wdy > 0.0) {
		float vy = vel_y[c];
		if (vy > 0.0) {
			int nu = nbr[b + 5u];
			if (nu >= 0 && solid[nu] == 0.0) { t += clamp(vy * wdy, 0.0, 0.3333); }
		} else if (vy < 0.0) {
			int nd = nbr[b + 0u];
			if (nd >= 0 && solid[nd] == 0.0) { t += clamp(-vy * wdy, 0.0, 0.3333); }
		}
	}
	float wdt = params.wdt;
	if (wdt > 0.0) {
		for (int l = 0; l < 4; ++l) {
			int m = nbr[b + uint(l + 1)];
			if (m < 0 || solid[m] != 0.0) { continue; }
			float mine = toward_link(c, l);
			if (mine > 0.0) { t += clamp(mine * wdt, 0.0, 0.3333); }
		}
	}
	return t;
}

// Scale that holds a cell's advective outflow inside the budget OUT_MAX leaves after diffusion has taken its
// share. `diffuse_frac` is a push constant, identical for every cell, so donor and gatherer agree on the cap.
float adv_scale(uint c) {
	float budget = max(0.0, OUT_MAX - params.diffuse_frac);
	float t = raw_adv_out(c);
	return (t > budget) ? (budget / t) : 1.0;
}

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

	// 2) VERTICAL WIND ADVECTION (vel_y = the buoyancy-driven radial-UP wind) — this is what makes cloud
	// CLUMP instead of forming a uniform veil. The old constant `rise_frac` lofted moisture everywhere at
	// the same rate, which (with diffusion) smears the field flat. Instead moisture rides the REAL vertical
	// wind: a warm updraft column (vel_y > 0) lifts humidity and, where the vertical flow CONVERGES (air
	// rising into me from below faster than it leaves above), CONCENTRATES it into a dense cloud mass;
	// subsidence (vel_y < 0) carries moisture back down toward warmer, higher-saturation air, which re-
	// evaporates it and opens CLEAR SKY between the masses. First-order upwind GATHER, mass-conserving
	// (every share a cell loses to a radial neighbour is exactly the share that neighbour gains), mirroring
	// the horizontal wind block below. Slot 5 = outward/up, slot 0 = inward/down.
	// OUT-SCALING (the dust_outscale_sphere3d.glsl pattern). Every advective share this cell sends is multiplied
	// by scale_g, and every neighbour gathers that same scaled share, so each face balances exactly.
	//
	// WHAT THIS REPLACES, AND WHY IT MATTERED: the old code summed unscaled shares — 6*d of diffusion plus up to
	// 0.3333 vertical plus up to 2*0.3333 lateral, which totals 1.035 at MOISTURE_DIFFUSE 0.035 — and then
	// floored the result with `q_out[g] = v > 0.0 ? v : 0.0`. Once the total passed 1.0 the donor stopped at zero
	// while its neighbours still gathered their full unscaled shares, so more vapour arrived than ever left.
	// THAT MADE WATER APPEAR FROM NOTHING, in exactly the strong-updraft and strong-wind cells where the
	// atmosphere is most active. With the shares scaled the floor is unreachable and it is gone: the retained
	// fraction is at least 1 - OUT_MAX = 0.1 and every inflow term is non-negative.
	float scale_g = adv_scale(g);

	float wdy = params.wdt_y;
	if (wdy > 0.0) {
		float vy = vel_y[g];
		// LOSE my share: up (slot 5) when rising, down (slot 0) when sinking — into an open cell only.
		if (vy > 0.0 && q > 0.0) {
			int nu = nbr[base + 5];
			if (nu >= 0 && solid[nu] == 0.0) { delta -= q * clamp(vy * wdy, 0.0, 0.3333) * scale_g; }
		} else if (vy < 0.0 && q > 0.0) {
			int nd = nbr[base + 0];
			if (nd >= 0 && solid[nd] == 0.0) { delta -= q * clamp(-vy * wdy, 0.0, 0.3333) * scale_g; }
		}
		// GAIN from the cell BELOW (slot 0) if it rises toward me.
		{
			int mb = nbr[base + 0];
			if (mb >= 0 && solid[mb] == 0.0) {
				float vb = vel_y[mb];
				if (vb > 0.0) { delta += q_in[mb] * clamp(vb * wdy, 0.0, 0.3333) * adv_scale(uint(mb)); }
			}
		}
		// GAIN from the cell ABOVE (slot 5) if it sinks toward me.
		{
			int ma = nbr[base + 5];
			if (ma >= 0 && solid[ma] == 0.0) {
				float va = vel_y[ma];
				if (va < 0.0) { delta += q_in[ma] * clamp(-va * wdy, 0.0, 0.3333) * adv_scale(uint(ma)); }
			}
		}
	}

	// 3) HORIZONTAL WIND — first-order upwind advection by the LOCAL per-cell velocity. wdt folds in
	// wind_gain*step_dt/cell_size; a cell with no matter sends nothing (q_in==0 contributes 0 in the gather).
	float wdt = params.wdt;
	if (wdt > 0.0) {
		// One sweep over the four lateral links. LOSE into every link this cell is blowing toward, GAIN from
		// every neighbour blowing back at me. In a face interior exactly one of each opposite pair has a
		// positive component, so this loses the same two shares the old per-axis form did.
		for (int l = 0; l < 4; ++l) {
			int m = nbr[base + l + 1];
			if (m < 0 || solid[m] != 0.0) {
				continue;
			}
			float mine = toward_link(g, l);
			if (mine > 0.0 && q > 0.0) {
				delta -= q * clamp(mine * wdt, 0.0, 0.3333) * scale_g;
			}
			float theirs = toward_link(uint(m), l ^ 1);
			if (theirs > 0.0) {
				delta += q_in[m] * clamp(theirs * wdt, 0.0, 0.3333) * adv_scale(uint(m));
			}
		}
	}

	// No floor here any more — see the out-scaling note above. `q + delta` retains at least (1 - OUT_MAX) of q
	// and adds only non-negative inflows, so it cannot go negative; the old `v > 0.0 ? v : 0.0` was the clamp
	// that turned an over-budget outflow into minted water instead of an error.
	q_out[g] = q + delta;
}
