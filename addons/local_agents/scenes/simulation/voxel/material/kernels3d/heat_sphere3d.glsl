#[compute]
#version 450

// CUBED-SPHERE heat conduction (Phase B template). The box port of heat3d.glsl gathered 6 neighbours by
// idx arithmetic (±1, ±dim_x, ±layer) with `if(ix>0)` boundary drops; here every cell gathers its 6
// neighbours from a precomputed INDEX TABLE `nbr[idx*6 + d]` (slot 0=inward/down, 1-4 lateral, 5=outward/up;
// -1 = boundary → skipped). This is the mechanical transformation EVERY field kernel follows for the sphere:
// replace the idx±offset + bounds-if with `int nb = nbr[idx*6+d]; if (nb >= 0) …`. Relax each cell toward the
// mean of its in-table neighbours by CONDUCT_FRACTION, double-buffered (read temp_in, write temp_out).

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer TempIn { float temp_in[]; };
layout(set = 0, binding = 1, std430) restrict writeonly buffer TempOut { float temp_out[]; };
layout(set = 0, binding = 2, std430) restrict readonly buffer Neigh { int nbr[]; };

layout(push_constant, std430) uniform Params {
	uint cell_count;
	uint pad0;
	uint pad1;
	uint pad2;
} params;

const float CONDUCT_FRACTION = 0.14;

void main() {
	uint idx = gl_GlobalInvocationID.x;
	if (idx >= params.cell_count) {
		return;
	}
	float here = temp_in[idx];
	float sum = 0.0;
	int n = 0;
	for (int d = 0; d < 6; d++) {
		int nb = nbr[idx * 6u + uint(d)];
		if (nb >= 0) {
			sum += temp_in[nb];
			n += 1;
		}
	}
	float mean = (n > 0) ? sum / float(n) : here;
	temp_out[idx] = here + (mean - here) * CONDUCT_FRACTION;
}
