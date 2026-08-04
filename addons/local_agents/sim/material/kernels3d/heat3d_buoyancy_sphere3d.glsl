#[compute]
#version 450

// CUBED-SPHERE heat BUOYANCY pass — the sphere port of heat3d_buoyancy.glsl (hot void rises radially
// outward). The box kernel was dispatched ONE INVOCATION PER XZ COLUMN and swept iy ASCENDING IN PLACE:
// a strictly SEQUENTIAL up-the-column update where heat pushed into a cell became visible to the next
// (higher) iteration in the same pass. That sweep ORDER cannot survive on the cubed sphere — there is no
// global "column" and no guaranteed ascending dispatch order. We drop the order dependence and reproduce
// the PHYSICAL INTENT (hot rises outward) as a RACE-FREE, DOUBLE-BUFFERED per-cell GATHER of the paired
// swap: each cell reads its OLD self + its OLD radial neighbours (slot 5 = above/outward, slot 0 =
// below/inward) and writes temp_out once.
//
// ===== IT MOVES ENERGY NOW, NOT DEGREES ===================================================================
// *(Corrected 2026-08-03. The paragraph that stood here described the box's paired exchange
//  `temp[i] -= BUOYANCY*d*0.5; temp[iu] += BUOYANCY*d*0.5` and asserted "the two halves are computed
//  independently in each invocation but pair up exactly, SO ENERGY IS CONSERVED". That claim was FALSE and it
//  is the reason this comment is here rather than a one-line diff.)*
//
// The old expression was symmetric in DEGREES and read no material channel at all. Degrees are not energy:
// this substrate's open cells run from air at rho*c = 1186 J/m^3/K to seawater at 4.171e6, a ratio of 3517.
// Taking one degree out of a water cell and putting one degree into the air cell above it therefore removed
// 4.171e6 joules per cubic metre and delivered 1186 — so every air/water radial bond ran as a one-way energy
// pump, deleting or creating heat depending on which way the gradient pointed. That bond is precisely the sea
// surface, where sea-surface temperature is set.
//
// What it does instead is what heat_sphere3d.glsl already does correctly for conduction: compute a heat FLUX
// across the bond and divide it by EACH SIDE'S OWN heat capacity.
//     Q  = BUOYANCY * 0.5 * min(rc_here, rc_nbr) * (T_hot - T_cold)      [J per m^3 of cell, per step]
//     dT_hot = -Q / rc_hot        dT_cold = +Q / rc_cold
// rc_hot*dT_hot + rc_cold*dT_cold = -Q + Q = 0 exactly, for any pair of materials, and both invocations
// compute the same Q because `min` is symmetric — so the gather stays race-free and now really does conserve.
// `min` is the physical part: convection carries the heat a parcel of the LIGHTER-capacity phase can hold, so
// warm sea barely cools while it warms the air above it, which is what a sea breeze is. For two cells of the
// same material it reduces exactly to the old 0.09*d, so air-over-air behaviour is unchanged.
//
// BUOYANCY originated in heat3d_buoyancy.glsl / MaterialHeat3D.gd; both are deleted, so the value below is
// the only one left. It is a model rate (what fraction of a bond's gradient convection closes per step), not
// a property of matter — the properties of matter are the rho*c values it is now multiplied by.
//
// Neighbour table `nbr[idx*6 + slot]`: slot 0 = inward/DOWN, 5 = outward/UP; -1 = boundary → no exchange.

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer TempIn { float temp_in[]; };
layout(set = 0, binding = 1, std430) restrict writeonly buffer TempOut { float temp_out[]; };
layout(set = 0, binding = 2, std430) restrict readonly buffer Solid { float solid[]; };
layout(set = 0, binding = 4, std430) restrict readonly buffer Snow { float snow[]; };
layout(set = 0, binding = 5, std430) restrict readonly buffer Water { float water[]; };
layout(set = 0, binding = 6, std430) restrict readonly buffer RockFill { float rock_fill[]; };
layout(set = 0, binding = 15, std430) restrict readonly buffer Neigh { int nbr[]; };  // idx*6 + slot

layout(push_constant, std430) uniform Params {
	uint cell_count;
	uint pad0;
	uint pad1;
	uint pad2;
} params;

// Constant — authoritative here. (Corrected 2026-07-29: said "MUST match heat3d_buoyancy.glsl /
// MaterialHeat3D.gd exactly"; both were deleted in the box->sphere migration.)
const float BUOYANCY = 0.18;

// Measured properties of matter, in volumetric heat capacity (J/m^3/K). GLSL cannot read GDScript, so these
// are copies; scripts/check_physical_constants.sh holds them equal to the authority.
const float RC_AIR   = 1186.0;    // LAPhysical.VOL_HEAT_CAP_AIR_J_M3K
const float RC_ROCK  = 2.436e6;   // LAPhysical.VOL_HEAT_CAP_ROCK_J_M3K
const float RC_WATER = 4.171e6;   // LAPhysical.VOL_HEAT_CAP_WATER_J_M3K
const float RC_SNOW  = 6.27e5;    // LAPhysical.VOL_HEAT_CAP_SNOW_J_M3K

// A cell's heat capacity from what it is made of, by VOLUME FRACTION. IDENTICAL text in heat_sphere3d.glsl
// (rc_of) and heat3d_solar_sphere3d.glsl (rc_of_cell); change one and change all three.
float rc_of(uint i) {
	if (solid[i] != 0.0) {
		return RC_ROCK;
	}
	float f_rock = clamp(rock_fill[i], 0.0, 1.0);
	float f_water = clamp(water[i], 0.0, 1.0);
	float f_snow = clamp(snow[i], 0.0, 1.0);
	float f_air = max(0.0, 1.0 - f_rock - f_water - f_snow);
	return RC_AIR * f_air + RC_ROCK * f_rock + RC_WATER * f_water + RC_SNOW * f_snow;
}

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
