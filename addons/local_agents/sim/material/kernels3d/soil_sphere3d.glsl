#[compute]
#version 450

#include "neighbours.glsli"

// r = gid % depth, so no elevation buffer is needed. NEIGHBOUR slots: 0=inward/down … 5=outward/up; -1=boundary.

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict buffer Water { float water[]; };            // settled surface water (in place)
layout(set = 0, binding = 1, std430) restrict readonly buffer Solid { float solid[]; };
layout(set = 0, binding = 3, std430) restrict buffer Send { float send[]; };                // idx*6 + dir (shared scratch)
layout(set = 0, binding = 4, std430) restrict readonly buffer SoilIn { float soil_in[]; };  // live soil (last step)
layout(set = 0, binding = 5, std430) restrict writeonly buffer SoilOut { float soil_out[]; };
layout(set = 0, binding = 6, std430) restrict readonly buffer Regolith { float regolith[]; }; // 1 = permeable aquifer rock
layout(set = 0, binding = 7, std430) restrict buffer Temp { float temp[]; };                // POST-thermal temp, carry-heat in place
layout(set = 0, binding = 8, std430) restrict readonly buffer Grain { float grain[]; };     // representative grain diameter, metres
layout(set = 0, binding = 9, std430) restrict buffer SoilDbg { float dbg[]; };              // per-leg budget probe
layout(set = 0, binding = 11, std430) restrict buffer Porosity { float porosity[]; };
layout(set = 0, binding = 15, std430) restrict readonly buffer Neigh { int nbr[]; };

layout(push_constant, std430) uniform Params {
	uint cell_count;
	uint pass_id;      // 0 = compute transfers → send, 1 = apply
	uint depth;        // radial shells per column (cell = col*depth + r)
	uint pad0;
	float core_radius;
	float cell_size;
	float shell_m;     // REAL metres one regolith shell stands for (LAPhysical.GROUNDWATER_CIRCULATION_M /
	                   // REGOLITH_CELLS) — the same subsurface scale LAMaterialFieldGeotherm3D derives its
	                   // gradient from, so the aquifer and the geotherm measure depth in one set of metres.
	float step_s;      // REAL seconds one field step stands for (LAMaterialFieldSphereStep3D)
} params;

// --- PERMEABILITY IS PORE GEOMETRY, NOT A NUMBER SOMEBODY PICKED -------------------------------------------
// a real flux — conduct = K * step_seconds / shell_metres — it means K = 4.05 m/s, which is twenty-six times
// Kozeny-Carman relation. No material table, no type enum: one relation, two continuous fields.
const float KOZENY_C = 180.0;              // LAPhysical.KOZENY_CARMAN_C
const float GRAVITY = 9.80665;             // LAPhysical.GRAVITY_M_S2
const float WATER_VISCOSITY = 1.002e-3;    // LAPhysical.WATER_DYNAMIC_VISCOSITY_PA_S
const float RHO_WATER = 997.0;             // LAPhysical.WATER_DENSITY_KG_M3
const float SURFACE_POROSITY = 0.40;       // LAPhysical.REGOLITH_SURFACE_POROSITY
const float COMPACTION_LEN_M = 2500.0;     // LAPhysical.COMPACTION_LENGTH_M
const int REG_CELLS = 4;                   // MUST match MaterialField3D.REGOLITH_CELLS

const float RC_AIR   = 1185.9;    // LAPhysical.VOL_HEAT_CAP_AIR_J_M3K
const float RC_ROCK  = 2.436e6;   // LAPhysical.VOL_HEAT_CAP_ROCK_J_M3K
const float RC_WATER = 4171448.0; // LAPhysical.VOL_HEAT_CAP_WATER_J_M3K

float reg_heat_cap(float phi, float s) {
	return (1.0 - phi) * RC_ROCK + s * RC_WATER + max(0.0, phi - s) * RC_AIR;
}

const float MAX_MASS = 1.0;           // surface water a cell holds before it is "full" (MUST match MaterialField3D
                                      // + water_sphere3d.glsl). An outlet at or above this can take no more, which
                                      // is what gives a spring its back-pressure.
const float MAX_FLOW_FRAC = 0.35;     // cap total outflow to this fraction of a cell's soil per step (stability)

// Shells of regolith standing OUTWARD of this one: 0 at the ground surface, increasing with burial. Read-only
// walk over the static regolith mask, so it is race-free and needs no extra channel.
int burial_shells(int c) {
	int d = 0;
	int walk = nbr[uint(c) * N_SLOTS + N_OUT];
	for (int k = 0; k < REG_CELLS; k++) {
		if (walk < 0 || regolith[walk] == 0.0) {
			break;
		}
		d++;
		walk = nbr[uint(walk) * N_SLOTS + N_OUT];
	}
	return d;
}

// Athy compaction: porosity, and therefore the cell's saturated water CAPACITY, at this burial depth.
float porosity_of(int c) {
	float z = (float(burial_shells(c)) + 0.5) * params.shell_m;
	return SURFACE_POROSITY * exp(-z / COMPACTION_LEN_M);
}

// Kozeny-Carman, then Darcy, then this substrate's units: the fraction of a cell that crosses a face in one
// step at UNIT hydraulic gradient. K = phi^3 d^2 rho g / (180 (1-phi)^2 mu); conduct = K * dt / L.
float conduct_of(int c, float phi) {
	float d = grain[c];
	float k_intrinsic = phi * phi * phi * d * d / (KOZENY_C * max((1.0 - phi) * (1.0 - phi), 1e-6));
	float k_sat = k_intrinsic * RHO_WATER * GRAVITY / WATER_VISCOSITY;      // m/s
	return k_sat * params.step_s / max(params.shell_m, 1e-6);
}
const float RESIDUAL = 0.30;          // fraction of CAPACITY held against gravity by capillarity. Field capacity
float k_rel(float s, float cap) {
	float se = clamp((s / max(cap, 1e-6) - RESIDUAL) / (1.0 - RESIDUAL), 0.0, 1.0);
	return se * se * se;
}
const float SEEP_THRESH = 0.9;        // fraction of CAPACITY above which a saturated cell overflows upward
const float SEEP_RATE = 0.5;          // fraction of the above-threshold surplus that seeps up per step
const float MIN_W = 0.002;            // surface water below this doesn't infiltrate
const float INFIL_RATE = 0.045;       // peak infiltration — under the rainfall rate so storms produce runoff
const float DRY_CRUST = 0.12;         // bone-dry infiltration fraction (hydrophobic crust → flash flood)
const float WET_KNEE = 0.25;          // soil fraction by which the ground has rehydrated to full infiltration

// Which leg a per-slot desired flow belongs to, so the budget-sharing loop can attribute it to the right probe
// slot after scaling. (The up-seep leg is tracked separately — it shares slot 5 with a possible spring.)
const int LEG_NONE = 0;
const int LEG_DARCY = 1;
const int LEG_SPRING = 2;

// ---- PER-LEG BUDGET PROBE (LAMaterialFieldSoilBudget3D reads this) ------------------------------------
// list A back in slot 2 — and on a cubed sphere that is a stronger claim than "adjacency is mutual", which
const uint DBG_SLOTS = 21u;
#define DBG_DARCY_SENT    0u   // regolith -> regolith (Darcy)
#define DBG_SPRING_SENT   1u   // regolith -> open (exfiltration / spring)
#define DBG_SEEP_SENT     2u   // regolith -> open, upward (waterlogged up-seep)
#define DBG_INFIL_SENT    3u   // open -> regolith, downward (infiltration)
#define DBG_REG_IN        4u   // soil_in  at a regolith cell (pre-kernel soil total)
#define DBG_REG_OUT       5u   // soil_out at a regolith cell (post-kernel soil total)
#define DBG_OWN_OUT       6u   // own_out  at a regolith cell (everything it debited)
#define DBG_DARCY_RECV    7u   // regolith cell's inflow whose donor is regolith
#define DBG_INFIL_RECV    8u   // regolith cell's inflow whose donor is open
#define DBG_CLAMP_GAIN    9u   // max(0,x)-x at a regolith cell: >0 means the clamp INVENTED soil
#define DBG_SPRING_RECV  10u   // open cell's inflow whose donor is regolith (spring + seep landing as water)
#define DBG_OPEN_DROP    11u   // soil_in at an open non-regolith cell, which pass 1 overwrites with 0
#define DBG_OPEN_FROM_OPEN 12u // open cell's inflow whose donor is also open (only reachable via a bad slot pairing)
#define DBG_BEDROCK_IN   13u   // inflow gathered by an inert bedrock cell — that branch ignores it, so it is LOST
#define DBG_SPRING_DOWN  14u   // discharged INWARD (slot 0) — a shell lower, i.e. downward percolation
#define DBG_SPRING_LAT   15u   // discharged laterally (slots 1-4) — the intended valley-wall spring
#define DBG_SPRING_UP    16u   // discharged OUTWARD (slot 5) through the spring branch (not the up-seep leg)
#define DBG_OPEN_CLAMP_GAIN 20u   // max(0,x)-x at an OPEN cell: >0 means the clamp INVENTED water
#define DBG_SPRING_WET   17u   // the part of spring_sent whose outlet already holds >= half a cell of water
#define DBG_SPRING_CAPPED 18u  // exf into an outlet with rock within 2 cells outward (cavity / carved channel)
#define DBG_SPRING_FREECOL 19u // exf into an outlet with >= 3 open cells above it (sea / lake / deep water)

float head_of(int c, float s, float cap) {
	int r = c % int(params.depth);
	float elev = params.core_radius + (float(r) + 0.5) * params.cell_size;
	float table = clamp(s / max(cap, 1e-6), 0.0, 1.0) * params.cell_size;   // water-table height inside the cell
	return elev + table;
}

void main() {
	uint g = gl_GlobalInvocationID.x;
	if (g >= params.cell_count) {
		return;
	}
	int idx = int(g);
	uint base = g * 6u;
	uint dbase = g * DBG_SLOTS;

	if (params.pass_id == 0u) {
		// ---- PASS 0: compute transfers into `send` (self-zero all 6 slots first) --------------------------
		send[base + N_IN] = 0.0; send[base + N_OUT] = 0.0; send[base + N_A0] = 0.0;
		send[base + N_A1] = 0.0; send[base + N_B0] = 0.0; send[base + N_B1] = 0.0;
		// Probe: zero the SENT legs before any early return, exactly as `send` is zeroed — an inert cell then
		// truthfully reports sending nothing.
		dbg[dbase + DBG_DARCY_SENT] = 0.0; dbg[dbase + DBG_SPRING_SENT] = 0.0;
		dbg[dbase + DBG_SEEP_SENT] = 0.0;  dbg[dbase + DBG_INFIL_SENT] = 0.0;
		dbg[dbase + DBG_SPRING_DOWN] = 0.0; dbg[dbase + DBG_SPRING_LAT] = 0.0;
		dbg[dbase + DBG_SPRING_UP] = 0.0;   dbg[dbase + DBG_SPRING_WET] = 0.0;
		dbg[dbase + DBG_SPRING_CAPPED] = 0.0; dbg[dbase + DBG_SPRING_FREECOL] = 0.0;

		bool is_regolith = regolith[g] != 0.0;
		// Publish phi for every cell, every step, before any early return. ZERO outside regolith, which is
		// the correct answer there and makes `rock_fill * (1.0 - porosity[i])` reduce to `rock_fill` for
		// bedrock with no branch at the consumer. This is the ONLY writer of the channel.
		porosity[g] = is_regolith ? porosity_of(int(g)) : 0.0;

		if (is_regolith) {
			// GROUNDWATER: flow to lower-head regolith neighbours (Darcy) + DAYLIGHT into open neighbours (springs).
			float s = soil_in[g];
			if (s <= 0.0) {
				return;
			}
			float my_cap = porosity_of(idx);
			float my_conduct = conduct_of(idx, my_cap);
			float my_head = head_of(idx, s, my_cap);
			float kr = k_rel(s, my_cap);
			float want[6];
			int leg[6];
			float total_want = 0.0;
			for (int d = 0; d < 6; d++) {
				want[d] = 0.0;
				leg[d] = LEG_NONE;
				int n = nbr[base + uint(d)];
				if (n < 0) {
					continue;
				}
				if (regolith[n] != 0.0) {
					// Darcy: flow toward lower head (elevation + table). Gravity is baked into the elevation term.
					float n_cap = porosity_of(n);
					float nh = head_of(n, soil_in[n], n_cap);
					float dh = my_head - nh;
					if (dh > 0.0) {
						float grad = dh / max(params.cell_size, 1e-6);
						// UPSTREAM weighting: the DONOR's rock is the one the water has to move through.
						float flow = min(my_conduct * kr * grad, max(0.0, n_cap - soil_in[n]));
						if (flow > 0.0) {
							want[d] = flow;
							leg[d] = LEG_DARCY;
							total_want += flow;
						}
					}
				} else if (solid[n] == 0.0) {
					int nr = n % int(params.depth);
					float open_floor = params.core_radius + (float(nr) + 0.5) * params.cell_size;
					float open_elev = open_floor + water[n] * params.cell_size;
					float exf_head = my_head - open_elev;
					if (exf_head > 0.0) {
						// remaining = MAX_FLOW_FRAC*s <= 0.21 and min() picked the stability cap EVERY time.
						float exf = my_conduct * kr * (exf_head / params.cell_size);
						//     exf_head = table + (1 - w)*cell_size >= table > 0
						exf = min(exf, max(0.0, MAX_MASS - water[n]));
						if (exf > 0.0) {
							want[d] = exf;
							leg[d] = LEG_SPRING;
							total_want += exf;
						}
					}
				}
			}
			float seep_want = 0.0;
			float surplus = s - my_cap * SEEP_THRESH;
			if (surplus > 0.0) {
				int up = nbr[base + N_OUT];
				if (up >= 0 && solid[up] == 0.0) {
					// open cell through N_OUT — two legs sharing one outlet must share its capacity, which the
					seep_want = min(surplus * SEEP_RATE, max(0.0, MAX_MASS - water[up] - want[N_OUT]));
					total_want += seep_want;
				}
			}

			// ---- SHARE THE BUDGET ------------------------------------------------------------------------
			if (total_want <= 0.0) {
				return;                                    // nothing wants to move; `send` is already zeroed
			}
			float scale = min(1.0, (s * MAX_FLOW_FRAC) / total_want);
			for (int d = 0; d < 6; d++) {
				float f = want[d] * scale;
				if (f <= 0.0) {
					continue;
				}
				send[base + uint(d)] = f;
				if (leg[d] == LEG_DARCY) {
					dbg[dbase + DBG_DARCY_SENT] += f;
					continue;
				}
				dbg[dbase + DBG_SPRING_SENT] += f;
				if (d == 0) { dbg[dbase + DBG_SPRING_DOWN] += f; }
				else if (d == 5) { dbg[dbase + DBG_SPRING_UP] += f; }
				else { dbg[dbase + DBG_SPRING_LAT] += f; }
				int n = nbr[base + uint(d)];
				if (water[n] >= 0.5) { dbg[dbase + DBG_SPRING_WET] += f; }
				// How tall is the OPEN column standing above this outlet? 3+ open cells = a real water
				// body (sea/lake); rock within 2 = a cavity or a carved channel, i.e. confined.
				int oc = 0;
				int walk = nbr[uint(n) * N_SLOTS + N_OUT];
				for (int k = 0; k < 3; k++) {
					if (walk < 0 || solid[walk] != 0.0) { break; }
					oc++;
					walk = nbr[uint(walk) * N_SLOTS + N_OUT];
				}
				if (oc >= 3) { dbg[dbase + DBG_SPRING_FREECOL] += f; }
				else { dbg[dbase + DBG_SPRING_CAPPED] += f; }
			}
			float seep = seep_want * scale;
			if (seep > 0.0) {
				send[base + N_B1] += seep;                   // += : slot 5 may already carry a scaled spring flow
				dbg[dbase + DBG_SEEP_SENT] += seep;
			}
			return;
		}

		// OPEN cell: infiltrate surface water DOWN into the regolith beneath it (dry-crust hump → flash floods).
		if (solid[g] == 0.0) {
			float w = water[g];
			if (w <= MIN_W) {
				return;
			}
			int ib = nbr[base + N_IN];
			if (ib < 0 || regolith[ib] == 0.0) {
				return;                                    // no aquifer directly below to soak into
			}
			float ib_cap = porosity_of(ib);
			float wet = clamp(soil_in[ib] / max(ib_cap, 1e-6), 0.0, 1.0);
			if (wet >= 1.0) {
				return;                                    // saturated below → it all runs off (flash flood)
			}
			float wetting = mix(DRY_CRUST, 1.0, smoothstep(0.0, WET_KNEE, wet));
			float cap_rate = INFIL_RATE * wetting * (1.0 - wet);
			float infil = min(w, min(cap_rate, ib_cap - soil_in[ib]));
			if (infil > 0.0) {
				send[base + N_IN] = infil;
				dbg[dbase + DBG_INFIL_SENT] = infil;
				float c_in = infil * RC_WATER;
				float c_rock = reg_heat_cap(ib_cap, soil_in[ib]);
				temp[ib] = (c_rock * temp[ib] + c_in * temp[g]) / (c_rock + c_in);
			}
		}
		return;
	}

	// ---- PASS 1: apply — each cell adds inflow to its own store, subtracts its own outflow ----------------
	float own_out = send[base + N_IN] + send[base + N_OUT] + send[base + N_A0]
		+ send[base + N_A1] + send[base + N_B0] + send[base + N_B1];
	float inflow = 0.0;
	float hot_flux = 0.0;
	float hot_mass = 0.0;
	// Probe: the same gather, split by DONOR TYPE, so "what regolith sent" can be compared against "what
	// arrived". from_reg = inflow whose donor is a regolith cell (Darcy, or a spring landing in open water);
	// from_open = inflow whose donor is an open cell (infiltration).
	float from_reg = 0.0;
	float from_open = 0.0;
	int nb; float sflow;
	// One loop over the six slots, crediting the OPPOSITE slot. It was six unrolled lines pairing
	// 0<->5, 1<->2, 3<->4, which is not the table's pairing — the aquifer both destroyed and duplicated water.
	for (uint d = 0u; d < N_SLOTS; ++d) {
		nb = nbr[base + d];
		if (nb < 0) { continue; }
		sflow = send[uint(nb) * N_SLOTS + opposite(d)];
		inflow += sflow;
		if (regolith[nb] != 0.0) {
			from_reg += sflow;
			if (sflow > 0.0) { hot_flux += sflow * temp[nb]; hot_mass += sflow; }
		} else {
			from_open += sflow;
		}
	}

	// Probe: zero every APPLY leg first, so each branch below only has to fill in the ones it owns.
	dbg[dbase + DBG_REG_IN] = 0.0;      dbg[dbase + DBG_REG_OUT] = 0.0;
	dbg[dbase + DBG_OWN_OUT] = 0.0;     dbg[dbase + DBG_DARCY_RECV] = 0.0;
	dbg[dbase + DBG_INFIL_RECV] = 0.0;  dbg[dbase + DBG_CLAMP_GAIN] = 0.0;
	dbg[dbase + DBG_SPRING_RECV] = 0.0; dbg[dbase + DBG_OPEN_DROP] = 0.0;
	dbg[dbase + DBG_OPEN_FROM_OPEN] = 0.0; dbg[dbase + DBG_BEDROCK_IN] = 0.0;
	dbg[dbase + DBG_OPEN_CLAMP_GAIN] = 0.0;

	if (regolith[g] != 0.0) {
		// Regolith: gains groundwater from higher-head neighbours + infiltration from above; loses outflow.
		float raw = soil_in[g] - own_out + inflow;
		float applied = max(0.0, raw);        // keep it in a local: SoilOut is `writeonly`, it cannot be read back
		soil_out[g] = applied;
		dbg[dbase + DBG_REG_IN] = soil_in[g];
		dbg[dbase + DBG_REG_OUT] = applied;
		dbg[dbase + DBG_OWN_OUT] = own_out;
		dbg[dbase + DBG_DARCY_RECV] = from_reg;
		dbg[dbase + DBG_INFIL_RECV] = from_open;
		dbg[dbase + DBG_CLAMP_GAIN] = applied - raw;
	} else if (solid[g] == 0.0) {
		float raw_w = water[g] - own_out + inflow;
		float applied_w = max(0.0, raw_w);
		water[g] = applied_w;
		dbg[dbase + DBG_OPEN_CLAMP_GAIN] = applied_w - raw_w;
		dbg[dbase + DBG_SPRING_RECV] = from_reg;
		dbg[dbase + DBG_OPEN_FROM_OPEN] = from_open;
		dbg[dbase + DBG_OPEN_DROP] = soil_in[g];     // overwritten with 0 on the next line — a sink if nonzero
		soil_out[g] = 0.0;
		// scripted: which springs are hot falls out of the head gradient meeting the geothermal heat field.
		if (hot_mass > 0.0) {
			float donor_t = hot_flux / hot_mass;
			// arrived. `water[g]` is read raw — the CA is compressible, so it can exceed one cell — and the air
			// share is whatever volume that leaves, floored at zero.
			float w_here = max(0.0, water[g] - hot_mass);
			float c_here = w_here * RC_WATER + max(0.0, 1.0 - w_here) * RC_AIR;
			float c_in = hot_mass * RC_WATER;
			temp[g] = (c_here * temp[g] + c_in * donor_t) / (c_here + c_in);
		}
	} else {
		soil_out[g] = soil_in[g];                          // impermeable bedrock: inert
		// ...and INERT means it drops `inflow` on the floor. Nothing ever sends to bedrock on purpose (Darcy
		// targets regolith, springs target open, infiltration targets a regolith floor), so a nonzero reading
		// here can only come from a gather that read a slot its donor did not aim at this cell — the seam.
		dbg[dbase + DBG_BEDROCK_IN] = inflow;
	}
}
