#[compute]
#version 450


layout(local_size_x = 64) in;

// Cementation and the solid flag. No mass moves here.
layout(set = 0, binding = 0, std430) restrict readonly buffer Silicate { float silicate[]; };
layout(set = 0, binding = 1, std430) restrict buffer Solid { float solid[]; };
// Consolidated share of this cell's silicate, 0..1.
layout(set = 0, binding = 2, std430) restrict buffer Cement { float cement[]; };
layout(set = 0, binding = 3, std430) restrict readonly buffer SilicateMelt { float silicate_melt[]; };
// Total pressure at this cell: the weight of the column above plus its own gas. Pa.
layout(set = 0, binding = 4, std430) restrict readonly buffer Pressure { float pressure[]; };
layout(set = 0, binding = 5, std430) restrict readonly buffer H2OBuf { float h2o[]; };
layout(set = 0, binding = 9, std430) restrict buffer Regolith { float regolith[]; };
layout(set = 0, binding = 10, std430) restrict buffer Grain { float grain[]; };

layout(push_constant, std430) uniform Params {
	uint cell_count;
	float fresh_grain_m;    // grain diameter given to newly-closed rock — LAPhysical.GRAIN_D_LOWLAND_M
	float lith_rate_per_pa; // LAPhysical.LITHIFICATION_RATE_PER_PA, per step per Pa of excess
	float lith_pressure_pa; // LAPhysical.LITHIFICATION_PRESSURE_PA
} params;

const float SOLID_IN = 0.6;    // LAPhysical.RHEOLOGICAL_LOCKUP_CRYSTAL_FRAC
const float SOLID_OUT = 0.4;   // LAPhysical.RHEOLOGICAL_MOBILE_CRYSTAL_FRAC

void main() {
	uint g = gl_GlobalInvocationID.x;
	if (g >= params.cell_count) {
		return;
	}
	float melt = clamp(silicate_melt[g], 0.0, 1.0);
	// A melt carries no cement.
	float cem = min(clamp(cement[g], 0.0, 1.0), 1.0 - melt);
	float excess = max(pressure[g] - params.lith_pressure_pa, 0.0);
	cem = clamp(cem + params.lith_rate_per_pa * excess * (1.0 - melt - cem), 0.0, 1.0 - melt);
	cement[g] = cem;

	float rock = max(silicate[g], 0.0) * cem;
	bool was = solid[g] != 0.0;
	bool now = was ? (rock >= SOLID_OUT) : (rock >= SOLID_IN);
	if (now) {
		// Enclosed h2o is now pore water: same channel, different place. The cell has become aquifer.
		if (h2o[g] > 0.0) {
			regolith[g] = 1.0;
			grain[g] = max(grain[g], params.fresh_grain_m);
		}
		solid[g] = 1.0;
		return;
	}
	solid[g] = 0.0;
}
