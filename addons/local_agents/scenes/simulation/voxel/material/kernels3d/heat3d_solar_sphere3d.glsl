#[compute]
#version 450

// CUBED-SPHERE heat SOLAR/AMBIENT pass — THE TERMINATOR. Sphere port of heat3d_solar.glsl. The box kernel
// dispatched one invocation per XZ COLUMN and relaxed ONLY that column's topmost cell toward a target built
// from a SINGLE GLOBAL scalar `params.solar` (sun energy x elevation, computed on the CPU) — the whole grid
// saw the same sun. On a planet that is wrong: the sun lights one HEMISPHERE. Here we dispatch PER CELL (like
// heat_sphere3d, `if (idx >= cell_count) return;`) and compute PER-CELL insolation from the cell's own outward
// radial vs a world-space sun direction, so the day side warms and the night side cools — the real terminator
// falls straight out of the temperature field.
//
// SURFACE / SKY cell on the sphere: there are no columns. A cell is a SKY-EXPOSED surface cell iff it is OPEN
// (solid == 0) and its OUTWARD-radial neighbour (nbr slot 5) is -1 (space boundary) or solid — i.e. it is the
// OUTERMOST open cell reached walking slot 5 outward until you hit -1 or rock. That local test is exactly the
// landing set of the "walk slot 5 outward" the box did by scanning a column from the top down, and because each
// surface cell only touches ITSELF it is race-free. Non-surface cells are left as conduction produced them
// (mirrors the box touching only the top cell). Runs AFTER conduction, IN PLACE on the temp buffer.
//
// PER-CELL SOLAR: insolation = max(0, dot(cell_radial, sun_dir)); cell_radial = the binding-14 outward unit
// vector for this cell, sun_dir = the NEW sun_x/sun_y/sun_z push-constant (world-space unit vector to the sun).
// target = AMBIENT_NIGHT + SOLAR_WARMTH * insolation, then relax by AMBIENT_RELAX. The night side relaxes to the
// bare AMBIENT_NIGHT floor; the sub-solar point to AMBIENT_NIGHT + SOLAR_WARMTH.
//
// ALTITUDE LAPSE — RESTORED (climate lane). The box target subtracted a lapse * (world_height - sea_level) so
// high ground read cold (snow-capped peaks + an alpine treeline at ANY latitude). The box→sphere port dropped
// it claiming "no per-cell world-position buffer is available." That claim is stale: the driver already packs a
// per-cell world position (`pos`, flat float3 c*3+{0,1,2}, the SAME buffer heat3d_cool binds) and hands it to
// this pass via `bufs["pos"]`. We bind it here (binding 3) and compute the cell's ALTITUDE above the sea shell
// = max(0, length(pos) - sea_radius), then subtract LAPSE * altitude from the insolation target. On the sphere
// "up" is the outward radial, so altitude is a radial distance above the sea-surface RADIUS (sea_radius, the
// same push param heat3d_cool uses) — not a planar height. This is pure GEOMETRY: a peak is cold because it is
// FAR FROM THE CENTRE, independent of where the sun is, so snow caps the highest terrain on the equator too and
// the treeline descends toward the poles (where the insolation base is already low). No special-case "mountain"
// or "snow" code — the cold peak falls out of one lapse term over the shared position field.
// Constants copied from MaterialHeat3D.gd; LAPSE tuned for the PLANET_RELIEF≈16 / sea_radius≈248 world scale.

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict buffer Temp { float temp[]; };
layout(set = 0, binding = 1, std430) restrict readonly buffer Solid { float solid[]; };
layout(set = 0, binding = 3, std430) restrict readonly buffer Pos { float pos[]; };          // per-cell world position, packed flat c*3+{0,1,2}
layout(set = 0, binding = 14, std430) restrict readonly buffer Radial { float radial[]; };  // per-cell outward unit vec, packed flat c*3+{0,1,2}
layout(set = 0, binding = 15, std430) restrict readonly buffer Neigh { int nbr[]; };         // idx*6 + slot

layout(push_constant, std430) uniform Params {
	uint cell_count;
	uint pad0;
	uint pad1;
	uint pad2;
	float sun_x;        // world-space unit vector pointing TOWARD the sun (magnitude carries insolation)
	float sun_y;
	float sun_z;
	float sea_radius;   // world radius of the sea shell — altitude datum for the lapse term
} params;

// Constants — MUST match MaterialHeat3D.gd exactly.
const float AMBIENT_NIGHT = 6.0;
const float SOLAR_WARMTH = 18.0;
const float AMBIENT_RELAX = 0.05;
// ALTITUDE LAPSE: °C dropped from the solar target per world-unit of altitude above the sea shell. Tuned so the
// highest peaks (~18 u above sea at PLANET_RELIEF 16) fall well below FREEZE_TEMP (12.5) even at the sub-solar
// equator (target 24 - 1.1*18 ≈ 4 °C → snow), while mid-slope land (~9 u) stays temperate (24 - 1.1*9 ≈ 14 °C).
const float LAPSE = 1.1;

void main() {
	uint idx = gl_GlobalInvocationID.x;
	if (idx >= params.cell_count) {
		return;
	}
	if (solid[idx] != 0.0) {
		return;                                            // rock is not a sky cell
	}
	// TWO insolation surfaces on the shell:
	//   * TOP-OF-ATMOSPHERE — the outermost open cell (its OUTWARD neighbour, slot 5, is space or rock). This is
	//     the historical terminator surface: the sun bakes/freezes the exposed top of the air column and
	//     conduction/buoyancy carry it down. Radius ≈ shell top for EVERY column, so a lapse here would be a
	//     near-uniform giant offset that just freezes the whole atmosphere — so the lapse does NOT apply here.
	//   * GROUND-HUGGING — an air cell resting directly ON terrain (its INWARD neighbour, slot 0, is solid rock).
	//     This is the set snow deposits on (matches snowice_sphere3d), and its RADIUS TRACKS THE TERRAIN, so its
	//     altitude above the sea shell varies from ~0 in the valleys to the relief height on the peaks. The lapse
	//     applies HERE, cooling high ground below freezing → snow-capped peaks + an alpine treeline at ANY
	//     latitude, straight out of geometry. Lowland ground stays at the full insolation target (temperate).
	int up = nbr[idx * 6u + 5u];
	int down = nbr[idx * 6u + 0u];
	bool top_of_atm = (up < 0) || (solid[up] != 0.0);
	bool ground_hug = (down >= 0) && (solid[down] != 0.0);
	if (!top_of_atm && !ground_hug) {
		return;
	}
	// Per-cell insolation from this cell's outward radial vs the sun direction (the terminator).
	uint rb = idx * 3u;
	vec3 cell_radial = vec3(radial[rb + 0u], radial[rb + 1u], radial[rb + 2u]);
	vec3 sun_dir = vec3(params.sun_x, params.sun_y, params.sun_z);
	float insolation = max(0.0, dot(cell_radial, sun_dir));

	float target = AMBIENT_NIGHT + SOLAR_WARMTH * insolation;
	if (ground_hug) {
		// ALTITUDE above the sea shell — the terrain elevation. Peaks are far from the centre → cold.
		float altitude = max(0.0, length(vec3(pos[rb + 0u], pos[rb + 1u], pos[rb + 2u])) - params.sea_radius);
		target -= LAPSE * altitude;
	}
	temp[idx] += AMBIENT_RELAX * (target - temp[idx]);
}
