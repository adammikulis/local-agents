#[compute]
#version 450

// field: one invocation per surface cell (dispatch over surf_count). The box kernel blurred toward its 4 lateral

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer FertIn  { float fert_in[]; };
layout(set = 0, binding = 1, std430) restrict writeonly buffer FertOut { float fert_out[]; };
layout(set = 0, binding = 15, std430) restrict readonly buffer Neigh  { int nbr[]; };

layout(push_constant, std430) uniform Params {
	uint cell_count;   // = surf_count
	uint pad0;
	uint pad1;
	float precip;
} params;

const float FERT_DECAY = 0.0015;
const float FERT_RAIN_LEACH = 0.02;
const float FERT_BLUR = 0.04;

void main() {
	uint cell = gl_GlobalInvocationID.x;
	if (cell >= params.cell_count) {
		return;
	}
	float leach = FERT_DECAY + params.precip * FERT_RAIN_LEACH;
	float here = fert_in[cell];
	float acc = 0.0;
	int links = 0;
	for (int d = 1; d < 5; d++) {
		int nb = nbr[cell * 6u + uint(d)];
		if (nb >= 0) {
			acc += FERT_BLUR * fert_in[uint(nb)];
			links += 1;
		}
	}
	acc += here * (1.0 - FERT_BLUR * float(links));

	fert_out[cell] = max(0.0, acc * (1.0 - leach));
}
