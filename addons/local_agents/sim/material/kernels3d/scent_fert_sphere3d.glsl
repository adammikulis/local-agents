#[compute]
#version 450

// CUBED-SPHERE SCENT — soil FERTILITY pass. Sphere port of scent_fert3d.glsl. This is a per-SURFACE-CELL 2D
// field: one invocation per surface cell (dispatch over surf_count). The box kernel blurred toward its 4 lateral
// column-neighbours by idx arithmetic (±1, ±dim_x) with dim-bounds ifs, then leached a slow fraction (faster in
// rain). On the sphere each surface cell blurs toward its 4 LATERAL neighbours from the surface index table
// nbr[cell*6 + d], slots 1..4 (radial slots 0 and 5 SKIPPED for this 2D surface field); a boundary slot -1 is
// skipped.
//
// This is a fully MECHANICAL conversion — the box already had no wind, only an isotropic FERT_BLUR. Reads only
// the OLD fertility snapshot (fert_in), writes fert_out → order-independent. Constants copied EXACTLY from
// MaterialScent3D.gd.
//
// CONSERVATION (2026-08-03). The line above used to continue "The self weight stays 1 - 4*FERT_BLUR (four blur
// contributions on the closed surface)", which was a leak whenever a cell had fewer than four links: the
// gather skips a -1 slot but the self weight assumed four, so the cell gave away more than anyone received.
// The self weight now counts the links the cell actually has. The LEACH term is still non-conservative and is
// still unfixed — it deletes nitrogen with nothing receiving it; see the note at the write below.

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

// Tunables — MUST match MaterialScent3D.gd exactly.
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
	// SOIL CREEP: blur toward the 4 LATERAL neighbours (table slots 1..4).
	//
	// The self weight counts the links this cell ACTUALLY has. It used to be a flat `1 - 4*FERT_BLUR` while the
	// gather loop below skipped any slot the table marks -1, so a cell short of a link kept less than it gave
	// away and nothing anywhere gained the difference — THAT DELETED NITROGEN at every such cell, every step.
	// Counting first makes the exchange balance for any link count: this cell gives FERT_BLUR to each real
	// neighbour and takes FERT_BLUR from each, so the blur alone moves nitrogen around without changing the
	// total. (On a closed cubed sphere every surface cell should have all four, in which case this is
	// arithmetically the old line -- but the loop was already written to tolerate -1, and a self weight that
	// disagrees with the gather is a leak waiting for the first cell that hits one.)
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

	// LEACHING. This is the one leg of this kernel that is NOT conservative and is NOT fixed here: `leach`
	// removes FERT_DECAY + precip*FERT_RAIN_LEACH of the cell's nitrogen every step and NO channel receives it,
	// so it is DELETED. In the world, rain washes nitrate down the soil column and eventually to the sea, where
	// it is still nitrogen; there is no dissolved-nutrient channel in the water for it to go to, and adding one
	// spans buffers this kernel does not bind. Measured on this tree it is the smallest leak in the substrate
	// (fert run-long drift +0.0005 units/step against a fert_total of 0.36 on a --planet-only run), which is
	// why it is reported rather than papered over with a fake sink. See the track report.
	fert_out[cell] = max(0.0, acc * (1.0 - leach));
}
