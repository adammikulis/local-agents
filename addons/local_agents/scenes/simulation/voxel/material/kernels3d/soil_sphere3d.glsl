#[compute]
#version 450

// CUBED-SPHERE GROUNDWATER AQUIFER — the water table that makes rivers perennial. Groundwater lives in the
// permeable REGOLITH (the top few solid shells of each column; deeper rock is impermeable BEDROCK). It flows
// by DARCY's law toward lower hydraulic HEAD, where head = cell elevation + the water-table height inside the
// cell. Gravity (the inward neighbour is a shell lower) fills the regolith from the bedrock up; the water table
// then levels laterally and flows toward lower terrain. Where the saturated regolith MEETS OPEN GROUND (a
// valley wall, a hillfoot) it DAYLIGHTS — exfiltrates as surface water = a SPRING. Surface water (the water CA)
// carries the spring flow downhill to the sea = a RIVER. Rain/snowmelt INFILTRATES from the surface to recharge
// the table (with a bone-dry hydrophobic crust so a deluge on baked ground runs off = flash flood). The bedrock
// floor is what stops the naive "all groundwater sinks to the core" and makes the aquifer surface-following.
//
// One 2-pass GATHER over the shared `send` scratch (each send = mass moved in a direction; the receiver adds it
// to soil if it is regolith, to surface water if it is open — the soil<->water phase change at the boundary is
// mass-conserving). Race-free: each cell writes only its own soil/water. Elevation is computed in-kernel from
// r = gid % depth, so no elevation buffer is needed. NEIGHBOUR slots: 0=inward/down … 5=outward/up; -1=boundary.

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict buffer Water { float water[]; };            // settled surface water (in place)
layout(set = 0, binding = 1, std430) restrict readonly buffer Solid { float solid[]; };
layout(set = 0, binding = 2, std430) restrict readonly buffer Static { float static_cells[]; };
layout(set = 0, binding = 3, std430) restrict buffer Send { float send[]; };                // idx*6 + dir (shared scratch)
layout(set = 0, binding = 4, std430) restrict readonly buffer SoilIn { float soil_in[]; };  // live soil (last step)
layout(set = 0, binding = 5, std430) restrict writeonly buffer SoilOut { float soil_out[]; };
layout(set = 0, binding = 6, std430) restrict readonly buffer Regolith { float regolith[]; }; // 1 = permeable aquifer rock
layout(set = 0, binding = 7, std430) restrict buffer Temp { float temp[]; };                // POST-thermal temp, carry-heat in place
layout(set = 0, binding = 8, std430) restrict readonly buffer Relevance { float relevance[]; };  // Keystone C
layout(set = 0, binding = 15, std430) restrict readonly buffer Neigh { int nbr[]; };

layout(push_constant, std430) uniform Params {
	uint cell_count;
	uint pass_id;      // 0 = compute transfers → send, 1 = apply
	uint depth;        // radial shells per column (cell = col*depth + r)
	uint step_index;   // monotonic field-step counter, for the relevance-gated update stride
	float core_radius;
	float cell_size;
} params;

// GLSL mirror of LALodStride.stride_for/should_run (runtime/LALodStride.gd) -- MUST match exactly.
int stride_for(float rel, int max_stride, int base_stride) {
	float r = max(rel, float(base_stride) / float(max_stride));
	return clamp(int(round(float(base_stride) / r)), base_stride, max_stride);
}
bool should_run(uint tick, uint phase, int stride) {
	return (tick + phase) % uint(stride) == 0u;
}
const int MAX_STRIDE = 16;

// Tuning.
const float CAPACITY = 0.60;          // groundwater a regolith cell holds when saturated (MUST match MaterialField3D)
const float CONDUCT = 0.35;           // Darcy conductivity: groundwater flow per unit head difference per step
const float MAX_FLOW_FRAC = 0.35;     // cap total outflow to this fraction of a cell's soil per step (stability)
// SPRINGS emerge where the water-table HEAD rises above an open neighbour's floor — i.e. at VALLEY WALLS where
// the regolith meets open ground laterally, NOT on flat ground (whose only open neighbour is straight up, which
// the table can't exceed unless brim-full). This auto-concentrates discharge at valleys and self-limits: seeping
// drains the local table, so a spring only SUSTAINS where groundwater keeps CONVERGING (a real valley). No fixed
// threshold, no blanket baseflow (which floods the whole surface). SPRING_CONDUCT = discharge per unit head.
const float SPRING_CONDUCT = 0.20;    // groundwater daylighting at valley walls. Paired with the exponential
                                      // (Clausius–Clapeyron) evap curve: exfiltrated baseflow now persists on
                                      // cool land instead of flashing off, so springs sustain visible streams.
// WATERLOGGED UP-SEEP: a regolith cell whose water table is near-full can hold no more groundwater, so the
// surplus wells UP into the open cell above = a water-table lake. Groundwater (Darcy) converges into low BASINS
// (nowhere lower to flow), saturates them, and this seep keeps them wet — PERENNIAL lakes fed by the aquifer's
// rain-recharged reservoir, not a one-shot seed. This is the artesian leg the sideways-only spring rule lacked.
const float SEEP_THRESH = 0.9;        // fraction of CAPACITY above which a saturated cell overflows upward
const float SEEP_RATE = 0.5;          // fraction of the above-threshold surplus that seeps up per step
const float MIN_W = 0.002;            // surface water below this doesn't infiltrate
// INFIL_RATE is deliberately SLOWER than the per-step rainfall so a storm's rain EXCEEDS the soil's intake
// and the surplus stays on the surface as RUNOFF (Hortonian/saturation overland flow) — which is what
// concentrates into streams and rivers. At the old 0.20 the ground drank rain faster than it fell, so every
// drop infiltrated into the aquifer and no surface water ever persisted (the planet ran bone-dry: land
// water_total ~2). The aquifer still recharges from this slower trickle + feeds perennial springs; the
// difference is that visible surface flow now survives long enough to carve drainage networks to the sea.
const float INFIL_RATE = 0.045;       // peak infiltration — under the rainfall rate so storms produce runoff
const float DRY_CRUST = 0.12;         // bone-dry infiltration fraction (hydrophobic crust → flash flood)
const float WET_KNEE = 0.25;          // soil fraction by which the ground has rehydrated to full infiltration

float head_of(int c, float s) {
	int r = c % int(params.depth);
	float elev = params.core_radius + (float(r) + 0.5) * params.cell_size;
	float table = clamp(s / CAPACITY, 0.0, 1.0) * params.cell_size;   // water-table height inside the cell
	return elev + table;
}

void main() {
	uint g = gl_GlobalInvocationID.x;
	if (g >= params.cell_count) {
		return;
	}
	int idx = int(g);
	uint base = g * 6u;

	if (params.pass_id == 0u) {
		// ---- PASS 0: compute transfers into `send` (self-zero all 6 slots first) --------------------------
		send[base + 0u] = 0.0; send[base + 1u] = 0.0; send[base + 2u] = 0.0;
		send[base + 3u] = 0.0; send[base + 4u] = 0.0; send[base + 5u] = 0.0;

		// RELEVANCE-GATED (Keystone C): only PASS 0's transfer compute is throttled — a quiescent cell's send[]
		// stays zeroed above (exactly what an inert cell already produces), but PASS 1 (below, unconditional)
		// still applies whatever a neighbour sent it this step, so a same-step inflow from an active neighbour
		// is never silently dropped.
		int stride = stride_for(relevance[g], MAX_STRIDE, 1);
		if (!should_run(params.step_index, g, stride)) {
			return;
		}

		if (static_cells[g] != 0.0) {
			return;                                        // sea reservoir: no aquifer here
		}
		bool is_regolith = regolith[g] != 0.0;

		if (is_regolith) {
			// GROUNDWATER: flow to lower-head regolith neighbours (Darcy) + DAYLIGHT into open neighbours (springs).
			float s = soil_in[g];
			if (s <= 0.0) {
				return;
			}
			float my_head = head_of(idx, s);
			float remaining = s * MAX_FLOW_FRAC;           // bounded total outflow this step
			for (int d = 0; d < 6; d++) {
				if (remaining <= 0.0) {
					break;
				}
				int n = nbr[base + uint(d)];
				if (n < 0) {
					continue;
				}
				if (regolith[n] != 0.0) {
					// Darcy: flow toward lower head (elevation + table). Gravity is baked into the elevation term.
					float nh = head_of(n, soil_in[n]);
					float dh = my_head - nh;
					if (dh > 0.0) {
						// Cap by the RECEIVER's remaining headroom too (mirror the infiltration cap) — else a cell
						// fills past CAPACITY, its head stops rising (head_of clamps the table at one cell_size),
						// and all groundwater funnels into the lowest regolith shell instead of levelling laterally
						// + feeding the upper-shell valley-wall springs (which would then dry out). This is what
						// keeps the water table surface-following + the springs perennial.
						float flow = min(CONDUCT * dh, remaining);
						flow = min(flow, max(0.0, CAPACITY - soil_in[n]));
						if (flow > 0.0) {
							send[base + uint(d)] = flow;
							remaining -= flow;
						}
					}
				} else if (solid[n] == 0.0 && static_cells[n] == 0.0) {
					// Open neighbour: SPRING if the water-table head is above this cell's floor. On flat ground the
					// only open neighbour is UP (floor a full cell higher) so nothing seeps; a valley-wall lateral
					// neighbour (floor at the same shell) daylights the whole table height → a spring. Discharge is
					// proportional to the head above the outlet, and it DRAINS the table, so a spring only sustains
					// where groundwater keeps converging (a real valley) — auto-concentrating, no blanket seep.
					int nr = n % int(params.depth);
					float open_elev = params.core_radius + (float(nr) + 0.5) * params.cell_size;
					float exf_head = my_head - open_elev;
					if (exf_head > 0.0) {
						float exf = min(remaining, SPRING_CONDUCT * exf_head);
						send[base + uint(d)] = exf;
						remaining -= exf;
					}
				}
			}
			// WATERLOGGED UP-SEEP: if the table is near-full (basin groundwater has nowhere lower to go), well the
			// surplus straight up into the open cell above → a perennial water-table lake sustained by the aquifer.
			float surplus = s - CAPACITY * SEEP_THRESH;
			if (surplus > 0.0 && remaining > 0.0) {
				int up = nbr[base + 5u];
				if (up >= 0 && solid[up] == 0.0 && static_cells[up] == 0.0) {
					float seep = min(remaining, surplus * SEEP_RATE);
					send[base + 5u] += seep;
					remaining -= seep;
				}
			}
			return;
		}

		// OPEN cell: infiltrate surface water DOWN into the regolith beneath it (dry-crust hump → flash floods).
		if (solid[g] == 0.0) {
			float w = water[g];
			if (w <= MIN_W) {
				return;
			}
			int ib = nbr[base + 0u];                       // inward / down
			if (ib < 0 || regolith[ib] == 0.0) {
				return;                                    // no aquifer directly below to soak into
			}
			float wet = clamp(soil_in[ib] / CAPACITY, 0.0, 1.0);
			if (wet >= 1.0) {
				return;                                    // saturated below → it all runs off (flash flood)
			}
			float wetting = mix(DRY_CRUST, 1.0, smoothstep(0.0, WET_KNEE, wet));
			float cap_rate = INFIL_RATE * wetting * (1.0 - wet);
			float infil = min(w, min(cap_rate, CAPACITY - soil_in[ib]));
			if (infil > 0.0) {
				send[base + 0u] = infil;
			}
		}
		return;
	}

	// ---- PASS 1: apply — each cell adds inflow to its own store, subtracts its own outflow ----------------
	if (static_cells[g] != 0.0) {
		soil_out[g] = soil_in[g];
		return;
	}
	float own_out = send[base + 0u] + send[base + 1u] + send[base + 2u]
		+ send[base + 3u] + send[base + 4u] + send[base + 5u];
	float inflow = 0.0;
	// Accumulate the geothermal heat riding the groundwater: for each REGOLITH donor that sent water into this
	// cell, track (inflow_i * donor_temp_i) and inflow_i, so an open cell can arrive at the inflow-weighted
	// donor temperature. Donors are regolith-only (open cells only push water DOWN), so no open temp is ever
	// read here — and regolith cells never WRITE temp in this pass — making the neighbour temp reads race-free.
	float hot_flux = 0.0;
	float hot_mass = 0.0;
	int nb; float sflow;
	nb = nbr[base + 0u]; if (nb >= 0) { sflow = send[uint(nb) * 6u + 5u]; inflow += sflow; if (regolith[nb] != 0.0 && sflow > 0.0) { hot_flux += sflow * temp[nb]; hot_mass += sflow; } }  // down-nbr sent UP into me
	nb = nbr[base + 5u]; if (nb >= 0) { sflow = send[uint(nb) * 6u + 0u]; inflow += sflow; if (regolith[nb] != 0.0 && sflow > 0.0) { hot_flux += sflow * temp[nb]; hot_mass += sflow; } }  // up-nbr sent DOWN into me
	nb = nbr[base + 1u]; if (nb >= 0) { sflow = send[uint(nb) * 6u + 2u]; inflow += sflow; if (regolith[nb] != 0.0 && sflow > 0.0) { hot_flux += sflow * temp[nb]; hot_mass += sflow; } }
	nb = nbr[base + 2u]; if (nb >= 0) { sflow = send[uint(nb) * 6u + 1u]; inflow += sflow; if (regolith[nb] != 0.0 && sflow > 0.0) { hot_flux += sflow * temp[nb]; hot_mass += sflow; } }
	nb = nbr[base + 3u]; if (nb >= 0) { sflow = send[uint(nb) * 6u + 4u]; inflow += sflow; if (regolith[nb] != 0.0 && sflow > 0.0) { hot_flux += sflow * temp[nb]; hot_mass += sflow; } }
	nb = nbr[base + 4u]; if (nb >= 0) { sflow = send[uint(nb) * 6u + 3u]; inflow += sflow; if (regolith[nb] != 0.0 && sflow > 0.0) { hot_flux += sflow * temp[nb]; hot_mass += sflow; } }

	if (regolith[g] != 0.0) {
		// Regolith: gains groundwater from higher-head neighbours + infiltration from above; loses outflow.
		soil_out[g] = max(0.0, soil_in[g] - own_out + inflow);
	} else if (solid[g] == 0.0) {
		// Open cell: gains spring exfiltration from regolith neighbours, loses infiltration it sent down.
		water[g] = max(0.0, water[g] - own_out + inflow);
		soil_out[g] = 0.0;
		// CARRY GEOTHERMAL HEAT: groundwater surfacing from hot regolith arrives at the donor rock's temperature.
		// Mix the incoming hot groundwater into the surface water already present (energy-conserving: the parcel's
		// heat is the rock's, continuously replenished by conduction from the core/magma). Water sourced from
		// deep/near-magma regolith surfaces HOT → the boiling/evap kernel steams it (a hot spring / fumarole);
		// water from cool shallow regolith surfaces cool → an ordinary spring. Nothing is scripted: which springs
		// are hot falls out of the head gradient meeting the existing geothermal heat field.
		if (hot_mass > 0.0) {
			float donor_t = hot_flux / hot_mass;
			float wnew = water[g];
			if (donor_t > temp[g] && wnew > 1.0e-6) {
				float frac = clamp(hot_mass / wnew, 0.0, 1.0);
				temp[g] = mix(temp[g], donor_t, frac);
			}
		}
	} else {
		soil_out[g] = soil_in[g];                          // impermeable bedrock: inert
	}
}
