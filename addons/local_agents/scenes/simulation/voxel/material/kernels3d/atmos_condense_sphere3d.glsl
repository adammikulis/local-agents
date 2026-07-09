#[compute]
#version 450

// CUBED-SPHERE atmosphere CONDENSATION — sphere port of atmos_condense3d.glsl (box). Per-cell dewpoint
// condensation + precipitation. Vapor past its OWN dewpoint condenses a CONDENSE_RATE share of the excess
// (into FOG when cool AND near the terrain, else CLOUD aloft); sub-saturated air re-evaporates condensate;
// both decay; thick cloud sheds rain; hot wet cells boil water to steam. ALL reaction math (dewpoint,
// condense/re-evap/decay/rain/boil) is copied VERBATIM from the box kernel. Only the two cross-cell tests
// are remapped onto the neighbour table:
//   - NEAR-GROUND test: the box scanned FOG_GROUND_CELLS cells straight DOWN (-layer); here we WALK the
//     INWARD radial neighbour (slot 0) up to FOG_GROUND_CELLS steps. Hitting the inward boundary (slot0 ==
//     -1 = world core/bottom) reads as ground, matching the box `jy < 0 → true`.
//   - OROGRAPHIC upwind test: the box tested a single DIAGONAL upwind cell (ix-wsx, iz-wsz). The sphere
//     6-table has no diagonal, so we test the UPWIND lateral neighbour on each axis that has wind: wind X
//     upwind = a-axis (blows +a ⇒ upwind is slot 1 (-a); blows -a ⇒ slot 2 (+a)); wind Z upwind = b-axis
//     (slot 3 / slot 4 the same way). oro = oro_gain if EITHER upwind neighbour is a rock face — solid, or
//     solid one step INWARD of it (its slot-0 neighbour), the sphere analogue of the box `solid[up-layer]`.
//
// NEIGHBOUR TABLE: nbr[idx*6 + d], slot 0=inward/down, 1=-a, 2=+a, 3=-b, 4=+b, 5=outward/up; -1 = boundary.

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer VaporIn { float vapor_in[]; };   // post-transport
layout(set = 0, binding = 1, std430) restrict buffer Cloud { float cloud[]; };                 // post-transport, in place
layout(set = 0, binding = 2, std430) restrict buffer Fog { float fog[]; };                     // post-transport, in place
layout(set = 0, binding = 3, std430) restrict readonly buffer Temp { float temp[]; };
layout(set = 0, binding = 4, std430) restrict readonly buffer Water { float water[]; };
layout(set = 0, binding = 5, std430) restrict readonly buffer Solid { float solid[]; };
layout(set = 0, binding = 6, std430) restrict readonly buffer Static { float static_cells[]; };
layout(set = 0, binding = 7, std430) restrict writeonly buffer VaporOut { float vapor_out[]; };
layout(set = 0, binding = 8, std430) restrict writeonly buffer Rain { float rain_out[]; };
layout(set = 0, binding = 9, std430) restrict writeonly buffer Boil { float boil_out[]; };  // dynamic water flashed to steam; drained by atmos_rain_sphere3d
layout(set = 0, binding = 15, std430) restrict readonly buffer Neigh { int nbr[]; };

layout(push_constant, std430) uniform Params {
	uint cell_count;
	float wind_x;      // world XZ wind (drives the orographic upwind test); X → a-axis
	float wind_z;      // Z → b-axis
	float oro_gain;    // extra condensation fraction at a windward slope face
} params;

// Constants — MUST match MaterialAtmosphere3D.gd exactly.
const float SAT_BASE = 0.06;
const float SAT_TEMP_GAIN = 0.055;
const float EVAP_TEMP_REF = 22.0;
const float CONDENSE_RATE = 0.30;
const float CLOUD_REEVAP_RATE = 0.12;
const float CLOUD_DECAY = 0.006;
const float RAIN_CLOUD_THRESHOLD = 0.45;
const float RAIN_RATE = 0.16;
const float FOG_MAX_TEMP = 12.0;
const float WATER_MIN = 0.05;
const int FOG_GROUND_CELLS = 2;
const float BOIL_TEMP = 100.0;
const float BOIL_RATE = 0.02;
const float BOIL_MAX_FRAC = 0.5;
const float STATIC_STEAM_MASS = 0.1;

// A cell is "near the ground" if solid rock, standing water, or the static sea lies within FOG_GROUND_CELLS
// cells directly INWARD of it (walking slot 0). The world core/bottom (slot0 == -1) reads as ground.
bool near_ground(int idx) {
	int cur = idx;
	for (int dd = 1; dd <= FOG_GROUND_CELLS; dd++) {
		cur = nbr[cur * 6 + 0];
		if (cur < 0) {
			return true;
		}
		if (solid[cur] != 0.0 || static_cells[cur] != 0.0 || water[cur] > WATER_MIN) {
			return true;
		}
	}
	return false;
}

// Is the given lateral upwind neighbour a windward rock face? (solid itself, or solid one step inward.)
bool oro_face(int up) {
	if (up < 0) {
		return false;
	}
	if (solid[up] != 0.0) {
		return true;
	}
	int below = nbr[up * 6 + 0];
	return (below >= 0 && solid[below] != 0.0);
}

void main() {
	uint g = gl_GlobalInvocationID.x;
	if (g >= params.cell_count) {
		return;
	}
	int idx = int(g);
	int base = idx * 6;

	if (solid[g] != 0.0) {
		vapor_out[g] = vapor_in[g];
		rain_out[g] = 0.0;
		boil_out[g] = 0.0;
		return;
	}

	float t = temp[g];
	float vap = vapor_in[g];
	float c = cloud[g];
	float f = fog[g];

	float sat = SAT_BASE * exp(SAT_TEMP_GAIN * (t - EVAP_TEMP_REF));
	if (vap > sat) {
		// OROGRAPHIC boost: humid air pressed against a windward rock face is forced up and condenses harder.
		// Upwind = opposite the wind sign, per lateral axis (X→a slots 1/2, Z→b slots 3/4).
		float oro = 0.0;
		if (params.wind_x != 0.0) {
			int upx = params.wind_x > 0.0 ? nbr[base + 1] : nbr[base + 2];
			if (oro_face(upx)) { oro = params.oro_gain; }
		}
		if (oro == 0.0 && params.wind_z != 0.0) {
			int upz = params.wind_z > 0.0 ? nbr[base + 3] : nbr[base + 4];
			if (oro_face(upz)) { oro = params.oro_gain; }
		}
		float cond = (vap - sat) * CONDENSE_RATE * (1.0 + oro);
		vap = vap - cond;
		if (t < FOG_MAX_TEMP && near_ground(idx)) {
			f += cond;
		} else {
			c += cond;
		}
	} else {
		float fr = f * CLOUD_REEVAP_RATE;
		float cr = c * CLOUD_REEVAP_RATE;
		f -= fr;
		c -= cr;
		vap = vap + fr + cr;
	}
	c *= (1.0 - CLOUD_DECAY);
	f *= (1.0 - CLOUD_DECAY);

	// BOILING — a wet cell hot enough to boil flashes standing water to rising vapor (mass-conserving): the
	// vapor is gained here, the DYNAMIC water is drained by the atmos_rain_sphere3d gather. The static sea
	// steams without draining (infinite reservoir). Mirrors MaterialAtmosphere3D.step() exactly.
	float boil = 0.0;
	if (t > BOIL_TEMP) {
		float bfrac = clamp((t - BOIL_TEMP) * BOIL_RATE, 0.0, BOIL_MAX_FRAC);
		if (static_cells[g] != 0.0) {
			vap += bfrac * STATIC_STEAM_MASS;
		} else if (water[g] > WATER_MIN) {
			boil = water[g] * bfrac;
			vap += boil;
		}
	}

	float rain = 0.0;
	if (c > RAIN_CLOUD_THRESHOLD) {
		rain = (c - RAIN_CLOUD_THRESHOLD) * RAIN_RATE;
		c -= rain;
	}

	vapor_out[g] = vap;
	cloud[g] = c;
	fog[g] = f;
	rain_out[g] = rain;
	boil_out[g] = boil;
}
