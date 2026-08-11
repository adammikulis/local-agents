#[compute]
#version 450

// Units: velocity m/s, k = dt_seconds / cell_metres. Advection is v*dt/dx.

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer TracerIn  { float tracer_in[]; };
layout(set = 0, binding = 1, std430) restrict writeonly buffer TracerOut { float tracer_out[]; };
// Where settled material lands, for a tracer that HAS a settled phase (dust -> sediment). A tracer with
// `deposit == 0` never writes here; the caller still binds something, and binds the tracer's own buffer if it
// has nothing better.
layout(set = 0, binding = 2, std430) restrict buffer Deposit { float deposit_ch[]; };
layout(set = 0, binding = 3, std430) restrict readonly buffer Solid { float solid[]; };
layout(set = 0, binding = 4, std430) restrict readonly buffer VelX { float vel_x[]; };
layout(set = 0, binding = 5, std430) restrict readonly buffer VelY { float vel_y[]; };
layout(set = 0, binding = 6, std430) restrict readonly buffer VelZ { float vel_z[]; };
layout(set = 0, binding = 15, std430) restrict readonly buffer Neigh   { int nbr[]; };      // idx*6 + slot
layout(set = 0, binding = 16, std430) restrict readonly buffer LinkTan { float ltan[]; };   // per-column dirs
layout(set = 0, binding = 17, std430) restrict readonly buffer SolidAngle { float solid_angle[]; };  // per column, sr

#include "cell_geom.glsli"

layout(push_constant, std430) uniform Params {
	uint cell_count;
	uint depth;           // radial shells per column — turns a cell index into its column for `ltan`
	float k;              // dt / cell_size, the Courant factor. REAL seconds over REAL model units.
	float settle_v;       // still-air settling velocity, m/s. Signed: >0 sinks, <0 rises.
	float diffuse;        // symmetric eddy-mixing share per open neighbour
	uint deposit;         // 1 = settled material becomes `deposit_ch`; 0 = the tracer is held in place
	uint offset;          // index base: channel-packed tracers (scent) pass ch*cell_count, others 0
	float decay;          // per-step fractional loss, 0 for a conserved tracer
	float core_radius;    // shell floor, model units
	float cell_size;      // radial thickness of one layer, model units
} params;

// Wind speed at which settling is fully suppressed, m/s.
const float SETTLE_CALM_REF = 6.0;
// Floor on the suppressed settling velocity, as a fraction of the still-air value.
const float SETTLE_MIN_RATIO = 0.08;
const float OUT_MAX = 0.9;

// Speed of cell `c` toward its lateral link `l` (0..3 == neighbour slots 1..4), in that cell's tangent frame.
// lattice did not carry, which is why O2 had no wind for as long as it was its own kernel. It carries it:
// `ltan`. The claim was refuted by the file sitting next to it.)*
float toward_link(uint c, int l) {
	uint b = ((c / max(params.depth, 1u)) * 4u + uint(l)) * 2u;
	return vel_x[c] * ltan[b] + vel_z[c] * ltan[b + 1u];
}

float share(float toward) {
	return max(0.0, toward) * params.k + params.diffuse;
}

// Downward flux share: gravitational settling suppressed by wind, plus any downdraft carrying it faster.
// Signed settling share of cell `i`: still-air settling velocity suppressed by wind, times the Courant
// factor. POSITIVE sinks, NEGATIVE rises. Callers split it across the two vertical faces — a share is an
// outflow fraction and can never be negative, so a rising tracer must be added to the UP face rather than
// subtracted from the DOWN one.
float settle_share(uint i) {
	float vxi = vel_x[i];
	float vyi = vel_y[i];
	float vzi = vel_z[i];
	float speed = sqrt(vxi * vxi + vyi * vyi + vzi * vzi);
	float calm = clamp(1.0 - speed / SETTLE_CALM_REF, 0.0, 1.0);
	float lo = params.settle_v * SETTLE_MIN_RATIO;
	return (lo + (params.settle_v - lo) * calm) * params.k;
}

// Downward share: the sinking half of `settle_share`, plus any downdraft carrying the tracer with it.
float fall_frac(uint i) {
	return max(0.0, -vel_y[i]) * params.k + max(0.0, settle_share(i));
}

// Upward share from buoyancy: the rising half. Zero for anything denser than air.
float rise_frac(uint i) {
	return max(0.0, -settle_share(i));
}

float raw_out(uint c) {
	uint b = c * 6u;
	float t = 0.0;
	for (int l = 0; l < 4; ++l) {
		int m = nbr[b + uint(l + 1)];
		if (m >= 0 && solid[m] == 0.0) { t += share(toward_link(c, l)); }
	}
	int cu = nbr[b + 5u];
	if (cu >= 0 && solid[cu] == 0.0) { t += share(vel_y[c]) + rise_frac(c); }
	int cd = nbr[b + 0u];
	if (cd >= 0 && solid[cd] == 0.0) { t += params.diffuse; }
	t += fall_frac(c);
	return t;
}

float out_scale(uint c) {
	float t = raw_out(c);
	return (t > OUT_MAX && t > 0.0) ? (OUT_MAX / t) : 1.0;
}

// A share is a fraction of the SENDER's own cell. The receiver is a different size, so the value it gains is
// the sent share times vol(sender)/vol(receiver).
float xfer(uint src, uint dst) {
	return cg_transfer(src, dst, params.depth, params.core_radius, params.cell_size);
}

void main() {
	uint g = gl_GlobalInvocationID.x;
	if (g >= params.cell_count) {
		return;
	}

	float ti = tracer_in[params.offset + g];

	if (solid[g] != 0.0) {
		if (params.deposit == 1u) {
			deposit_ch[g] += ti;
			tracer_out[params.offset + g] = 0.0;
		} else {
			tracer_out[params.offset + g] = ti;
		}
		return;
	}

	uint base = g * 6u;
	int nb_d = nbr[base + 0u];
	int nb_u = nbr[base + 5u];
	bool open_d = (nb_d >= 0) && (solid[nb_d] == 0.0);
	bool open_u = (nb_u >= 0) && (solid[nb_u] == 0.0);

	float scale_g = out_scale(g);

	// EXCHANGE — every share this cell sends is scaled by scale_g, and every neighbour gathers that SAME
	// scaled share off its own reverse link, so the flux across a face is one number both ends agree on and
	// the operator is conservative to the face. Nothing is added outside the scaling.
	float raw = 0.0;
	float gain = 0.0;
	for (int l = 0; l < 4; ++l) {
		int m = nbr[base + uint(l + 1)];
		if (m < 0 || solid[m] != 0.0) {
			continue;
		}
		raw += share(toward_link(g, l));
		gain += tracer_in[params.offset + uint(m)] * share(toward_link(uint(m), l ^ 1)) * out_scale(uint(m))
			* xfer(uint(m), g);
	}
	if (open_u) { raw += share(vel_y[g]) + rise_frac(g); }
	if (open_d) { raw += params.diffuse; }   // the settling half of the downward face is fall_frac, below
	raw += fall_frac(g);

	// Vertical inflow: the cell below blowing UP into us (advection + mixing), and the cell above sending its
	// whole downward flux — its settling plus the mixing share.
	if (open_d) { gain += tracer_in[params.offset + uint(nb_d)] * (share(vel_y[nb_d]) + rise_frac(uint(nb_d))) * out_scale(uint(nb_d)) * xfer(uint(nb_d), g); }
	if (open_u) { gain += tracer_in[params.offset + uint(nb_u)] * (fall_frac(uint(nb_u)) + params.diffuse) * out_scale(uint(nb_u)) * xfer(uint(nb_u), g); }

	float value = ti * (1.0 - raw * scale_g) + gain;

	// DEPOSIT — this cell's own downward flux that meets SOLID ground (or the floor) settles out here. If the
	if (params.deposit == 1u && ti > 0.0 && !open_d) {
		float dep = ti * fall_frac(g) * scale_g;
		if (dep > 0.0) {
			deposit_ch[g] += dep;
		}
	}

	tracer_out[params.offset + g] = value * (1.0 - params.decay);
}
