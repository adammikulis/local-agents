#[compute]
#version 450

// swap: each cell reads its OLD self + its OLD radial neighbours (slot 5 = above/outward, slot 0 =
// this substrate's open cells run from air at rho*c = 1186 J/m^3/K to seawater at 4.171e6, a ratio of 3517.
//     Q  = BUOYANCY * 0.5 * min(rc_here, rc_nbr) * (T_hot - T_cold)      [J per m^3 of cell, per step]
//     dT_hot = -Q / rc_hot        dT_cold = +Q / rc_cold
// Neighbour table `nbr[idx*6 + slot]`: slot 0 = inward/DOWN, 5 = outward/UP; -1 = boundary → no exchange.

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer TempIn { float temp_in[]; };
layout(set = 0, binding = 1, std430) restrict writeonly buffer TempOut { float temp_out[]; };
layout(set = 0, binding = 2, std430) restrict readonly buffer Solid { float solid[]; };
layout(set = 0, binding = 4, std430) restrict readonly buffer Snow { float snow[]; };
layout(set = 0, binding = 5, std430) restrict readonly buffer Water { float water[]; };
layout(set = 0, binding = 6, std430) restrict readonly buffer RockFill { float rock_fill[]; };
layout(set = 0, binding = 15, std430) restrict readonly buffer Neigh { int nbr[]; };  // idx*6 + slot
// CARRIERS THIS KERNEL DOES NOT USE ITSELF, bound because rc_shared.glsli needs every one of them.
// Leaving one out is exactly the divergence that file exists to end.
layout(set = 0, binding = 20, std430) restrict readonly buffer Lava { float lava[]; };
layout(set = 0, binding = 21, std430) restrict readonly buffer Fuel { float fuel[]; };
layout(set = 0, binding = 22, std430) restrict readonly buffer Biomass { float biomass[]; };
layout(set = 0, binding = 23, std430) restrict readonly buffer Detritus { float detritus[]; };

layout(push_constant, std430) uniform Params {
	uint cell_count;
	uint pad0;
	uint pad1;
	uint pad2;
} params;

// MaterialHeat3D.gd exactly"; both were deleted in the box->sphere migration.)
const float BUOYANCY = 0.18;

// Measured properties of matter, in volumetric heat capacity (J/m^3/K). GLSL cannot read GDScript, so these
// are copies; scripts/check_physical_constants.sh holds them equal to the authority.

layout(set = 0, binding = 30, std430) restrict readonly buffer Sediment { float sediment[]; };
layout(set = 0, binding = 31, std430) restrict readonly buffer Susp { float susp[]; };
layout(set = 0, binding = 32, std430) restrict readonly buffer Dust { float dust[]; };
layout(set = 0, binding = 33, std430) restrict readonly buffer Carbonate { float carbonate[]; };
layout(set = 0, binding = 34, std430) restrict readonly buffer Silica { float silica[]; };
layout(set = 0, binding = 35, std430) restrict readonly buffer Soil { float soil[]; };
layout(set = 0, binding = 36, std430) restrict readonly buffer Moisture { float moisture[]; };
layout(set = 0, binding = 37, std430) restrict readonly buffer Fungus { float fungus[]; };
layout(set = 0, binding = 38, std430) restrict readonly buffer Porosity { float porosity[]; };
#include "rc_shared.glsli"

void main() {
	uint idx = gl_GlobalInvocationID.x;
	if (idx >= params.cell_count) {
		return;
	}
	float here = temp_in[idx];
	// Solid cells hold no void heat to convect — pass through unchanged.
	if (solid[idx] != 0.0) {
		temp_out[idx] = here;
		return;
	}
	uint base = idx * 6u;
	float rc_here = max(rc_of(idx), 1.0);
	float delta = 0.0;

	// LOSE heat upward: if this cell is hotter than the open cell ABOVE (slot 5), it convects energy out.
	int iu = nbr[base + 5u];
	if (iu >= 0 && solid[iu] == 0.0) {
		float d = here - temp_in[iu];
		if (d > 0.0) {
			float q = BUOYANCY * 0.5 * min(rc_here, rc_of(uint(iu))) * d;
			delta -= q / rc_here;
		}
	}

	// GAIN the matching heat from below: if the open cell BELOW (slot 0) is hotter, its energy rises into us.
	// The same `q` the cell below computed for this bond, divided by OUR capacity instead of its own.
	int ib = nbr[base + 0u];
	if (ib >= 0 && solid[ib] == 0.0) {
		float d = temp_in[ib] - here;
		if (d > 0.0) {
			float q = BUOYANCY * 0.5 * min(rc_of(uint(ib)), rc_here) * d;
			delta += q / rc_here;
		}
	}

	temp_out[idx] = here + delta;
}
