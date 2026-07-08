#[compute]
#version 450

// CUBED-SPHERE FUNGUS — the emergent DECOMPOSER CA. Sphere port of fungus3d.glsl. The reaction body (growth,
// decomposition, death/decay, the aerobic O₂ cap, the fertility deposit) is UNCHANGED — only the SPORE gather
// is converted: the box kernel summed neighbour fungus by idx arithmetic (±1, ±dim_x, ±layer) with dim-bounds
// ifs + a solid[] wall test; here it loops the precomputed INDEX TABLE nbr[idx*6 + d] (boundary slot -1 skipped)
// and still skips solid neighbours, so spores never cross stone. All six slots are symmetric (no gravity).
//
// Reads fung_in (self + neighbours for spores), mutates detritus/co2/o2 IN PLACE (each write touches only its
// own cell → race-free), writes fung_out (ping-pong) and a per-cell fert_out. Constants copied EXACTLY from
// MaterialFungus3D.gd.

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer FungIn  { float fung_in[]; };
layout(set = 0, binding = 1, std430) restrict writeonly buffer FungOut { float fung_out[]; };
layout(set = 0, binding = 2, std430) restrict buffer Detritus { float detritus[]; };
layout(set = 0, binding = 3, std430) restrict buffer CO2 { float co2[]; };
layout(set = 0, binding = 4, std430) restrict buffer O2  { float o2[]; };
layout(set = 0, binding = 5, std430) restrict readonly buffer Temp  { float temp[]; };
layout(set = 0, binding = 6, std430) restrict readonly buffer Vapor { float vapor[]; };
layout(set = 0, binding = 7, std430) restrict readonly buffer Fire  { float fire[]; };
layout(set = 0, binding = 8, std430) restrict readonly buffer Solid { float solid[]; };
layout(set = 0, binding = 9, std430) restrict writeonly buffer FertOut { float fert_out[]; };
layout(set = 0, binding = 15, std430) restrict readonly buffer Neigh { int nbr[]; };

layout(push_constant, std430) uniform Params {
	uint cell_count;
	uint pad0;
	uint pad1;
	uint pad2;
	float precip;
	float pad3;
	float pad4;
	float pad5;
} params;

// Substrate thresholds + rates — MUST match MaterialFungus3D.gd exactly.
const float DETRITUS_MIN = 0.05;
const float FUNGUS_MIN = 0.02;
const float FUNGUS_MAX = 3.0;
const float MOIST_MIN = 0.02;
const float MOIST_REF = 0.06;
const float VAPOR_MOIST = 1.0;
const float RAIN_MOIST = 0.5;
const float DETRITUS_DAMP = 0.15;
const float TEMP_WARM = 42.0;
const float TEMP_COLD = 0.0;
const float FIRE_MIN = 0.02;
const float GROW_RATE = 0.06;
const float SPREAD = 0.02;
const float DECOMPOSE_RATE = 0.05;
const float CO2_PER_DECOMPOSE = 1.0;
const float O2_PER_DECOMPOSE = 0.8;
const float FERT_PER_DECOMPOSE = 1.5;
const float DECAY = 0.02;
const float DRY_DECAY = 0.06;

void main() {
	uint i = gl_GlobalInvocationID.x;
	if (i >= params.cell_count) {
		return;
	}
	fert_out[i] = 0.0;
	if (solid[i] != 0.0) {
		fung_out[i] = 0.0;
		return;
	}

	float d = detritus[i];
	float g = fung_in[i];
	// Moisture: air humidity + active rain + the dampness of the rotting matter itself.
	float moist = VAPOR_MOIST * vapor[i] + RAIN_MOIST * params.precip + DETRITUS_DAMP * clamp(d, 0.0, 1.0);
	float t = temp[i];
	bool scorched = t > TEMP_WARM || fire[i] > FIRE_MIN;
	bool frozen = t < TEMP_COLD;
	bool dry = moist < MOIST_MIN;
	bool favourable = d > DETRITUS_MIN && !scorched && !frozen && !dry;
	float gnew = g;

	// 1) GROWTH + SPREAD — only on damp, cool, detritus-bearing cells.
	if (favourable) {
		float mfac = clamp(moist / MOIST_REF, 0.0, 1.0);
		gnew += GROW_RATE * d * mfac;
		// Spores gathered from the six OPEN neighbours via the sphere index table.
		float spore = 0.0;
		for (int dd = 0; dd < 6; dd++) {
			int nb = nbr[i * 6u + uint(dd)];
			if (nb >= 0 && solid[nb] == 0.0) {
				spore += fung_in[nb];
			}
		}
		gnew += SPREAD * spore;
	}
	if (gnew > FUNGUS_MAX) {
		gnew = FUNGUS_MAX;
	}

	// 2) DECOMPOSITION (the loop-closer) — fungus rots detritus into CO₂ + fertility, drawing O₂.
	if (g > FUNGUS_MIN && d > DETRITUS_MIN) {
		float consumed = DECOMPOSE_RATE * g * d;
		if (consumed > d) {
			consumed = d;
		}
		// Aerobic: never rot more than the available O₂ supports.
		float o2_cap = o2[i] / O2_PER_DECOMPOSE;
		if (consumed > o2_cap) {
			consumed = o2_cap;
		}
		if (consumed > 0.0) {
			detritus[i] = d - consumed;
			d = detritus[i];
			co2[i] += CO2_PER_DECOMPOSE * consumed;
			o2[i] = max(0.0, o2[i] - O2_PER_DECOMPOSE * consumed);
			fert_out[i] = FERT_PER_DECOMPOSE * consumed;
		}
	}

	// 3) DEATH / DECAY — dies back fast where hot/frozen/dry or the food is exhausted.
	if (scorched || frozen || dry || d <= DETRITUS_MIN) {
		gnew -= DRY_DECAY * gnew;
	} else {
		gnew -= DECAY * gnew;
	}
	fung_out[i] = max(0.0, gnew);
}
