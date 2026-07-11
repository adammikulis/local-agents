#[compute]
#version 450

// CUBED-SPHERE SOIL WATER / WATER-TABLE CA — the ground's water reservoir. Surface water INFILTRATES down
// into the ground cell beneath it (up to a holding CAPACITY), the ground stores it as `soil`, and the ground
// slowly releases it back to the surface as BASEFLOW (a trickle that keeps rivers flowing between storms) plus
// SATURATION OVERFLOW when the soil is full. This is the reservoir that was missing: without it land water
// drained/evaporated in seconds; with it, rain is banked in the soil and fed out slowly, so rivers persist.
//
// INFILTRATION IS A HUMP, not a ramp — this is what makes floods realistic. Infiltration capacity is:
//   • LOW when the soil is BONE-DRY — baked/hydrophobic ground REPELS water (a crust), so a sudden deluge on
//     drought-hardened ground mostly RUNS OFF → flash flood. Drought CAUSES floods.
//   • HIGH at MODERATE moisture — rehydrated, pores open, the ground drinks well.
//   • LOW again when SATURATED — no room, so it sheds.
// So the FIRST rain on baked ground floods; only after it softens does the ground start soaking it up.
//
// The exchange is PURELY VERTICAL across the air↔ground interface (an open cell and the SOLID ground cell
// directly below it), so soil lives in the top ground layer. It is a 2-pass GATHER exactly like the water CA:
// pass 0 records the vertical transfers into the shared `send` scratch (slot 0 = infiltration DOWN, slot 5 =
// exfiltration UP); pass 1 applies each cell's own half. Both endpoints compute the same transfer from the
// same inputs, so mass is conserved and no two threads write the same cell (race-free). Water is modified
// IN PLACE on the settled back buffer (same as AtmospherePass's rain); soil ping-pongs live→back.
// Lateral groundwater flow (the table moving to daylight distant springs) is a later pass; this is the
// vertical infiltrate/store/release core. (Constants chosen for a slow, buffering reservoir — tune freely.)
//
// NEIGHBOUR TABLE: nbr[idx*6 + d], slot 0 = inward/radial-DOWN, 5 = outward/radial-UP; -1 = boundary.

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict buffer Water { float water[]; };            // settled surface water (in place)
layout(set = 0, binding = 1, std430) restrict readonly buffer Solid { float solid[]; };
layout(set = 0, binding = 2, std430) restrict readonly buffer Static { float static_cells[]; };
layout(set = 0, binding = 3, std430) restrict buffer Send { float send[]; };                // idx*6 + dir (shared scratch)
layout(set = 0, binding = 4, std430) restrict readonly buffer SoilIn { float soil_in[]; };  // live soil (last step)
layout(set = 0, binding = 5, std430) restrict writeonly buffer SoilOut { float soil_out[]; };
layout(set = 0, binding = 15, std430) restrict readonly buffer Neigh { int nbr[]; };

layout(push_constant, std430) uniform Params {
	uint cell_count;
	uint pass_id;   // 0 = compute transfers → send, 1 = apply
	uint pad0;
	uint pad1;
} params;

// Tuning — a SLOW buffering reservoir. CAPACITY is how much water a ground cell holds; INFIL_RATE caps how
// fast the surface soaks in; BASEFLOW is the trickle released to the surface each step (perennial rivers);
// overflow above CAPACITY is shed immediately (flash-flood behaviour). MIN_W ignores a dry trace.
const float CAPACITY = 0.60;
const float INFIL_RATE = 0.20;        // peak infiltration (at moderate moisture); modulated by the hump below
const float DRY_CRUST = 0.12;         // bone-dry infiltration as a fraction of peak (hydrophobic/baked crust)
const float WET_KNEE = 0.25;          // soil fraction by which the ground has rehydrated to full infiltration
const float BASEFLOW = 0.0025;
// Low threshold on purpose: the soil pass runs right after rain (before the next step's evaporation), so a
// THIN film of fresh rain/snowmelt must be able to soak in and be BANKED in the soil before it evaporates —
// this is how diffuse precip recharges the table. Too high a gate and ambient rain never wets the ground.
const float MIN_W = 0.002;

void main() {
	uint g = gl_GlobalInvocationID.x;
	if (g >= params.cell_count) {
		return;
	}
	uint base = g * 6u;

	if (params.pass_id == 0u) {
		// ---- PASS 0: compute the vertical transfers into `send` (self-zero all 6 slots first) --------------
		send[base + 0u] = 0.0;
		send[base + 1u] = 0.0;
		send[base + 2u] = 0.0;
		send[base + 3u] = 0.0;
		send[base + 4u] = 0.0;
		send[base + 5u] = 0.0;

		bool is_solid = solid[g] != 0.0;
		bool is_static = static_cells[g] != 0.0;
		if (is_static) {
			return;                                  // the calm sea reservoir does not infiltrate/store
		}

		if (!is_solid) {
			// OPEN cell: infiltrate surface water DOWN into the ground cell beneath it, up to its remaining room.
			float w = water[g];
			if (w <= MIN_W) {
				return;
			}
			int ib = nbr[base + 0u];                 // inward / down
			if (ib < 0 || solid[ib] == 0.0 || static_cells[ib] != 0.0) {
				return;                              // nothing solid (ground) below to soak in
			}
			float wet = clamp(soil_in[ib] / CAPACITY, 0.0, 1.0);   // 0 = bone-dry, 1 = saturated
			if (wet >= 1.0) {
				return;                              // saturated: no room → it all runs off (flash flood)
			}
			// HUMP: bone-dry ground repels (DRY_CRUST), climbs to full as it rehydrates (WET_KNEE), then the
			// room term (1-wet) chokes it off toward saturation. So a deluge on baked ground mostly sheds.
			float wetting = mix(DRY_CRUST, 1.0, smoothstep(0.0, WET_KNEE, wet));
			float cap_rate = INFIL_RATE * wetting * (1.0 - wet);
			float infil = min(w, min(cap_rate, CAPACITY - soil_in[ib]));
			if (infil > 0.0) {
				send[base + 0u] = infil;             // sent DOWN into the ground
			}
			return;
		}

		// SOLID ground cell: release soil UP to the open cell above (baseflow + any saturation overflow).
		float s = soil_in[g];
		if (s <= 0.0) {
			return;
		}
		int iu = nbr[base + 5u];                     // outward / up
		if (iu < 0 || solid[iu] != 0.0 || static_cells[iu] != 0.0) {
			return;                                  // no open air/water above to seep into
		}
		float exf = min(s, BASEFLOW);                // slow perennial baseflow
		if (s > CAPACITY) {
			exf += (s - CAPACITY);                   // saturated ground sheds the excess at once (flash runoff)
		}
		exf = min(exf, s);
		if (exf > 0.0) {
			send[base + 5u] = exf;                   // sent UP to the surface
		}
		return;
	}

	// ---- PASS 1: apply each cell's own half ---------------------------------------------------------------
	bool is_solid = solid[g] != 0.0;
	bool is_static = static_cells[g] != 0.0;
	if (is_static) {
		soil_out[g] = soil_in[g];
		return;
	}

	if (!is_solid) {
		// OPEN cell: lose the water it infiltrated down, gain what the ground below exfiltrated up.
		float infil_sent = send[base + 0u];
		float exf_recv = 0.0;
		int ib = nbr[base + 0u];
		if (ib >= 0) {
			exf_recv = send[uint(ib) * 6u + 5u];     // ground below sent UP (slot 5)
		}
		water[g] = max(0.0, water[g] - infil_sent + exf_recv);
		soil_out[g] = 0.0;                           // open cells hold no soil
		return;
	}

	// SOLID ground cell: lose what it released up, gain what the surface above infiltrated down.
	float exf_sent = send[base + 5u];
	float infil_recv = 0.0;
	int iu = nbr[base + 5u];
	if (iu >= 0) {
		infil_recv = send[uint(iu) * 6u + 0u];       // open cell above sent DOWN (slot 0)
	}
	soil_out[g] = max(0.0, soil_in[g] - exf_sent + infil_recv);
}
