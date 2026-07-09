#[compute]
#version 450

// CUBED-SPHERE SOLID DERIVE (rock unification Stage B). `solid` is no longer an independent source of truth
// seeded once from the SDF and never updated — it is a cheap per-cell DERIVED CACHE of the authoritative
// fractional mineral channel `rock_fill`: a cell is bedrock iff it holds at least half a cell of rock mass.
//   solid[g] = (rock_fill[g] >= SOLID_THRESHOLD) ? 1.0 : 0.0
// This runs FIRST every step (before any pass reads `solid`), so all ~10 downstream kernels that gate on
// `solid == 0.0` (water/lava flow, slump, dust/gas transport, thermal, atmos, reactions, …) see the current
// derived value without any change to their code. When nothing melts/solidifies, rock_fill stays exactly the
// seeded {0.0, 1.0} mask, so this reproduces the old `solid` mask bit-for-bit and the sim is unchanged.
// When lava solidifies (M5 record: lava -> rock_fill) rock_fill crosses 0.5 UP → the cell becomes solid; when
// rock melts (M6 record / add_lava: rock_fill -> lava) it crosses DOWN → the cell opens. The 0.5 crossing is
// exactly what Stage C will stamp into the SDF mesh; this kernel exposes it as the `solid` flag today.

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer RockFill { float rock_fill[]; };
layout(set = 0, binding = 1, std430) restrict writeonly buffer Solid { float solid[]; };

layout(push_constant, std430) uniform Params {
	uint cell_count;
	uint pad0;
	uint pad1;
	uint pad2;
} params;

const float SOLID_THRESHOLD = 0.5;   // half a cell of mineral mass = bedrock (MUST match MaterialField3D / Stage C stamp)

void main() {
	uint g = gl_GlobalInvocationID.x;
	if (g >= params.cell_count) {
		return;
	}
	solid[g] = (rock_fill[g] >= SOLID_THRESHOLD) ? 1.0 : 0.0;
}
