#[compute]
#version 450

// CUBED-SPHERE heat BUOYANCY pass — the sphere port of heat3d_buoyancy.glsl (hot void rises radially
// outward). The box kernel was dispatched ONE INVOCATION PER XZ COLUMN and swept iy ASCENDING IN PLACE:
// a strictly SEQUENTIAL up-the-column update where heat pushed into a cell became visible to the next
// (higher) iteration in the same pass. That sweep ORDER cannot survive on the cubed sphere — there is no
// global "column" and no guaranteed ascending dispatch order. We drop the order dependence and reproduce
// the PHYSICAL INTENT (hot rises outward) as a RACE-FREE, DOUBLE-BUFFERED per-cell GATHER of the paired
// swap: each cell reads its OLD self + its OLD radial neighbours (slot 5 = above/outward, slot 0 =
// below/inward) and writes temp_out once. The box's paired exchange `temp[i]-=move; temp[iu]+=move` with
// move = BUOYANCY*(temp[i]-temp[iu])*0.5 is split symmetrically: cell i LOSES `move` to the cell above it
// (when i is hotter), and GAINS the matching `move` from the cell below it (when below is hotter) — the two
// halves are computed independently in each invocation but pair up exactly, so energy is conserved with no
// sequential coupling. Constant copied EXACTLY from heat3d_buoyancy.glsl / MaterialHeat3D.gd.
//
// Neighbour table `nbr[idx*6 + slot]`: slot 0 = inward/DOWN, 5 = outward/UP; -1 = boundary → no exchange.

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer TempIn { float temp_in[]; };
layout(set = 0, binding = 1, std430) restrict writeonly buffer TempOut { float temp_out[]; };
layout(set = 0, binding = 2, std430) restrict readonly buffer Solid { float solid[]; };
layout(set = 0, binding = 15, std430) restrict readonly buffer Neigh { int nbr[]; };  // idx*6 + slot

layout(push_constant, std430) uniform Params {
	uint cell_count;
	uint pad0;
	uint pad1;
	uint pad2;
} params;

// Constant — MUST match heat3d_buoyancy.glsl / MaterialHeat3D.gd exactly.
const float BUOYANCY = 0.18;

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
	float delta = 0.0;

	// LOSE a share upward: if this cell is hotter than the open cell ABOVE (slot 5), it convects heat out.
	int iu = nbr[base + 5u];
	if (iu >= 0 && solid[iu] == 0.0) {
		float d = here - temp_in[iu];
		if (d > 0.0) {
			delta -= BUOYANCY * d * 0.5;
		}
	}

	// GAIN a share from below: if the open cell BELOW (slot 0) is hotter than us, its heat rises into us.
	int ib = nbr[base + 0u];
	if (ib >= 0 && solid[ib] == 0.0) {
		float d = temp_in[ib] - here;
		if (d > 0.0) {
			delta += BUOYANCY * d * 0.5;
		}
	}

	temp_out[idx] = here + delta;
}
