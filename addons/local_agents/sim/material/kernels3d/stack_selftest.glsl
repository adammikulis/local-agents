#[compute]
#version 450

// ONE CELL, AT REST. The six faces of a cube must return exactly the weight of what it holds, or a cell
// standing still accelerates. scripts/check_stack_balance.gd dispatches this and reads the residual.
#include "stack.glsli"

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict buffer Probe { float probe[]; };

// Floats per case: edge, g, m_cond, m_total, p_mean, then the gravity direction.
const uint LA_CASE = 8u;

void main() {
	uint i = gl_GlobalInvocationID.x * LA_CASE;
	float edge = probe[i];
	float g = probe[i + 1u];
	float m_cond = probe[i + 2u];
	float m_total = probe[i + 3u];
	float p_mean = probe[i + 4u];
	vec3 gh = normalize(vec3(probe[i + 5u], probe[i + 6u], probe[i + 7u]));
	vec3 pgf = vec3(0.0);
	for (uint d = 0u; d < 6u; ++d) {
		uint ax = d >> 1u;
		float s = (d & 1u) == 1u ? 1.0 : -1.0;
		vec3 n = vec3(ax == 0u ? s : 0.0, ax == 1u ? s : 0.0, ax == 2u ? s : 0.0);
		pgf -= la_stack_face_p(dot(n, gh), edge, g, m_cond, m_total, p_mean) * n / edge;
	}
	probe[i] = length(pgf + m_total * g * gh) / (m_total * g);
}
