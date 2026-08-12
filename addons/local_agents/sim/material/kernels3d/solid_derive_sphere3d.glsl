#[compute]
#version 450


layout(local_size_x = 64) in;

// --- WHAT HAPPENS TO THE LOOSE MATERIAL WHEN A CELL TURNS TO ROCK ------------------------------------------
layout(set = 0, binding = 0, std430) restrict buffer RockFill { float rock_fill[]; };
layout(set = 0, binding = 1, std430) restrict buffer Solid { float solid[]; };
layout(set = 0, binding = 2, std430) restrict buffer Sediment { float sediment[]; };
layout(set = 0, binding = 3, std430) restrict buffer Susp { float susp[]; };
layout(set = 0, binding = 4, std430) restrict buffer Dust { float dust[]; };
layout(set = 0, binding = 5, std430) restrict buffer H2OBuf { float h2o[]; };
layout(set = 0, binding = 9, std430) restrict buffer Regolith { float regolith[]; };
layout(set = 0, binding = 10, std430) restrict buffer Grain { float grain[]; };
// rock_fill is a saturation, so converting a volume fraction into it needs the cell's solid share.
layout(set = 0, binding = 38, std430) restrict readonly buffer Porosity { float porosity[]; };

layout(push_constant, std430) uniform Params {
	uint cell_count;
	float fresh_grain_m;   // grain diameter given to newly-closed rock — LAPhysical.GRAIN_D_LOWLAND_M, the
	                       // valley-fill alluvium end member, because a fresh deposit is unconsolidated clastic
	uint pad1;
	uint pad2;
} params;

// Rheological lock-up is HYSTERETIC: a crystallising melt stops flowing near 0.6 crystals and a solid does
// not start flowing again until about 0.4. One threshold makes a cell hovering at half melt flip every
const float SOLID_IN = 0.6;    // LAPhysical.RHEOLOGICAL_LOCKUP_CRYSTAL_FRAC
const float SOLID_OUT = 0.4;   // LAPhysical.RHEOLOGICAL_MOBILE_CRYSTAL_FRAC

void main() {
	uint g = gl_GlobalInvocationID.x;
	if (g >= params.cell_count) {
		return;
	}
	float rf = rock_fill[g];
	bool was = solid[g] != 0.0;
	bool now = was ? (rf >= SOLID_OUT) : (rf >= SOLID_IN);
	if (now) {
		// LITHIFY the loose phases into the bedrock they are now inside. rock_fill is a SATURATION -- the
		// pore-free share -- while sediment, susp and dust are volume fractions, so the loose material has
		float loose = sediment[g] + susp[g] + dust[g];
		if (loose > 0.0) {
			float solid_share = max(1.0 - clamp(porosity[g], 0.0, 1.0), 1.0e-6);
			rock_fill[g] = rf + loose / solid_share;
			sediment[g] = 0.0;
			susp[g] = 0.0;
			dust[g] = 0.0;
		}
		// The h2o the closing rock encloses is now PORE water — the same channel, a different place — so
		// nothing moves. What changes is that the cell has become aquifer.
		if (h2o[g] > 0.0) {
			regolith[g] = 1.0;
			grain[g] = max(grain[g], params.fresh_grain_m);
		}
		solid[g] = 1.0;
		return;
	}
	solid[g] = 0.0;
}
