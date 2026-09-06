#[compute]
#version 450

#include "bindings.glsli"

// (V rho / K) p'_c + dt^2 sum_f (A_f / d_f) (p'_c - p'_n) = -dt sum_f A_f (m*.n)_f, assembled here
// off flux.glsl's face predictor and converged by LAAcousticSolve.

#include "neighbours.glsli"

layout(local_size_x = 64) in;

layout(set = 0, binding = LA_BIND_HZ_COMP, std430) restrict readonly buffer HzComp { float hz_comp[]; };        // kg/Pa
layout(set = 0, binding = LA_BIND_HZ_RHS, std430) restrict writeonly buffer HzRhs { float hz_rhs[]; };          // kg
layout(set = 0, binding = LA_BIND_HZ_FLUX, std430) restrict readonly buffer HzFlux { float hz_flux[]; };        // kg/s out of the owning cell
layout(set = 0, binding = LA_BIND_HZ_COND, std430) restrict readonly buffer HzCond { float hz_cond[]; };        // m
layout(set = 0, binding = LA_BIND_HZ_P, std430) restrict buffer HzP { float hz_p[]; };              // Pa

const uint MODE_ASSEMBLE = 0u;

layout(push_constant, std430) uniform Params {
	uint cell_count;
	uint mode;
	float dt_s;
} params;


// The mass the predictor sends out over the step, negated; a cell with no row holds no pressure.
void assemble(uint c) {
	float open = 0.0;
	float flux = 0.0;
	for (uint f = la_face_lo(c); f < la_face_hi(c); ++f) {
		flux += hz_flux[f];
		open += hz_cond[f];
	}
	if (hz_comp[c] <= 0.0 && open <= 0.0) {
		hz_rhs[c] = 0.0;
		hz_p[c] = 0.0;
		return;
	}
	hz_rhs[c] = -params.dt_s * flux;
}


void main() {
	uint c = gl_GlobalInvocationID.x;
	if (c >= params.cell_count) {
		return;
	}
	if (params.mode == MODE_ASSEMBLE) {
		assemble(c);
	}
}
