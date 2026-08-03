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
layout(set = 0, binding = 9, std430) restrict buffer SoilDbg { float dbg[]; };              // per-leg budget probe
layout(set = 0, binding = 15, std430) restrict readonly buffer Neigh { int nbr[]; };

layout(push_constant, std430) uniform Params {
	uint cell_count;
	uint pass_id;      // 0 = compute transfers → send, 1 = apply
	uint depth;        // radial shells per column (cell = col*depth + r)
	uint pad0;
	float core_radius;
	float cell_size;
} params;

// Tuning.
const float CAPACITY = 0.60;          // groundwater a regolith cell holds when saturated (MUST match MaterialField3D)
const float MAX_MASS = 1.0;           // surface water a cell holds before it is "full" (MUST match MaterialField3D
                                      // + water_sphere3d.glsl). An outlet at or above this can take no more, which
                                      // is what gives a spring its back-pressure.
const float CONDUCT = 0.35;           // Darcy conductivity: groundwater flow per unit head difference per step
const float MAX_FLOW_FRAC = 0.35;     // cap total outflow to this fraction of a cell's soil per step (stability)
// SPRINGS emerge where the water-table HEAD rises above an open neighbour's floor — i.e. at VALLEY WALLS where
// the regolith meets open ground laterally, NOT on flat ground (whose only open neighbour is straight up, which
// the table can't exceed unless brim-full). This auto-concentrates discharge at valleys and self-limits: seeping
// drains the local table, so a spring only SUSTAINS where groundwater keeps CONVERGING (a real valley). No fixed
// threshold, no blanket baseflow (which floods the whole surface). SPRING_CONDUCT = discharge per step at UNIT
// HYDRAULIC GRADIENT (head difference divided by cell size), i.e. the same dimensionless currency as INFIL_RATE
// below — NOT per unit head in world units, which is what it used to be and why every spring pinned at the cap.
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

// ---- PER-LEG BUDGET PROBE (LAMaterialFieldSoilBudget3D reads this) ------------------------------------
// Each cell writes ONLY its own DBG_SLOTS floats, so the probe is as race-free as the channel writes beside
// it and needs no atomics. Summing a slot over the whole grid on the CPU gives that leg's per-step total.
//
// SENT (pass 0) and RECEIVED (pass 1) are deliberately SEPARATE legs for the same transfer. A gather kernel
// only conserves mass if the neighbour table is SLOT-OPPOSITE reciprocal — cell A's slot-1 neighbour must
// list A back in slot 2 — and on a cubed sphere that is a stronger claim than "adjacency is mutual", which
// is all LASphereGrid.validate() ever checked. Where the two differ the sender debits a slot nobody reads.
// sent != received IS that leak, measured rather than argued.
const uint DBG_SLOTS = 20u;
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
// Where exfiltration actually goes. The head term was added so a seabed cell could not spring into the ocean
// above it; these four say whether that worked, by splitting the SAME spring_sent four ways.
#define DBG_SPRING_DOWN  14u   // discharged INWARD (slot 0) — a shell lower, i.e. downward percolation
#define DBG_SPRING_LAT   15u   // discharged laterally (slots 1-4) — the intended valley-wall spring
#define DBG_SPRING_UP    16u   // discharged OUTWARD (slot 5) through the spring branch (not the up-seep leg)
#define DBG_SPRING_WET   17u   // the part of spring_sent whose outlet already holds >= half a cell of water
// `open_elev` can only ever see ONE cell of water, because it is `open_floor + clamp(water[n],0,1)*cell_size`.
// These two say whether that blindness matters: an outlet with a tall OPEN column above it is a sea or lake
// whose real weight the formula is throwing away; an outlet CAPPED by rock within two cells is a cavity or a
// carved channel, where the free-surface reading is not the right physics either (it is confined).
#define DBG_SPRING_CAPPED 18u  // exf into an outlet with rock within 2 cells outward (cavity / carved channel)
#define DBG_SPRING_FREECOL 19u // exf into an outlet with >= 3 open cells above it (sea / lake / deep water)

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
	uint dbase = g * DBG_SLOTS;

	if (params.pass_id == 0u) {
		// ---- PASS 0: compute transfers into `send` (self-zero all 6 slots first) --------------------------
		send[base + 0u] = 0.0; send[base + 1u] = 0.0; send[base + 2u] = 0.0;
		send[base + 3u] = 0.0; send[base + 4u] = 0.0; send[base + 5u] = 0.0;
		// Probe: zero the SENT legs before any early return, exactly as `send` is zeroed — an inert cell then
		// truthfully reports sending nothing.
		dbg[dbase + DBG_DARCY_SENT] = 0.0; dbg[dbase + DBG_SPRING_SENT] = 0.0;
		dbg[dbase + DBG_SEEP_SENT] = 0.0;  dbg[dbase + DBG_INFIL_SENT] = 0.0;
		dbg[dbase + DBG_SPRING_DOWN] = 0.0; dbg[dbase + DBG_SPRING_LAT] = 0.0;
		dbg[dbase + DBG_SPRING_UP] = 0.0;   dbg[dbase + DBG_SPRING_WET] = 0.0;
		dbg[dbase + DBG_SPRING_CAPPED] = 0.0; dbg[dbase + DBG_SPRING_FREECOL] = 0.0;

		bool is_regolith = regolith[g] != 0.0;

		if (is_regolith) {
			// GROUNDWATER: flow to lower-head regolith neighbours (Darcy) + DAYLIGHT into open neighbours (springs).
			float s = soil_in[g];
			if (s <= 0.0) {
				return;
			}
			float my_head = head_of(idx, s);
			float remaining = s * MAX_FLOW_FRAC;           // bounded total outflow this step
			// KNOWN, NOT FIXED HERE: this loop spends `remaining` greedily in SLOT ORDER and breaks when it runs
			// out. Slot 0 is the INWARD neighbour and head_of() makes the cell below always lower-head unless it
			// is brim-full, so whenever the cell beneath has headroom the outflow budget is spent downward before
			// any lateral Darcy or spring runs. That is why the table equilibrates in the bottom regolith shells
			// with the top ones dry, and why the header's claim that "the bedrock floor makes the aquifer
			// surface-following" does not hold. The fix is proportional allocation (compute all six desired flows,
			// then scale them to the budget together) — deliberately NOT done in the same change as the units fix
			// below, because it restructures a conservation-critical gather and deserves its own verification.
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
						// DARCY ON A GRADIENT, NOT ON A RAW HEAD. `dh` is a LENGTH in world units, so
						// `CONDUCT * dh` was 0.35 * (up to a full cell_size = 16) = 5.6 against a budget of at
						// most MAX_FLOW_FRAC * CAPACITY = 0.21 — min() picked the stability cap on EVERY link,
						// every step, so the aquifer was a fixed 35%/step drain that was head-proportional in
						// name only. This is the identical defect this file already found and fixed for
						// SPRING_CONDUCT 30 lines below ("SPRING_CONDUCT multiplied a head in WORLD units ...
						// min() picked the stability cap EVERY time"); it was never applied to the leg above it.
						// Dividing by cell_size makes CONDUCT what its comment always claimed: flow per unit
						// hydraulic gradient, the same dimensionless currency as INFIL_RATE.
						float grad = dh / max(params.cell_size, 1e-6);
						float flow = min(CONDUCT * grad, remaining);
						flow = min(flow, max(0.0, CAPACITY - soil_in[n]));
						if (flow > 0.0) {
							send[base + uint(d)] = flow;
							remaining -= flow;
							dbg[dbase + DBG_DARCY_SENT] += flow;
						}
					}
				} else if (solid[n] == 0.0) {
					// Open neighbour: SPRING if the water-table head is above the WATER LEVEL IT DISCHARGES INTO.
					// On flat ground the only open neighbour is UP (a full cell higher) so nothing seeps; a
					// valley-wall lateral neighbour daylights the table height → a spring. Discharge is proportional
					// to the head difference and DRAINS the table, so a spring only sustains where groundwater keeps
					// converging (a real valley) — auto-concentrating, no blanket seep.
					//
					// THE OUTLET HEAD INCLUDES THE NEIGHBOUR'S STANDING WATER, and that term is what replaced the
					// static mask here. This used to compare against the bare cell elevation and skip static
					// neighbours outright (`static_cells[n] == 0.0`) — a fake standing in for precisely this
					// physics, because a seabed regolith cell would otherwise "spring" into the ocean sitting on
					// top of it. Measured when the mask was removed WITHOUT this term: soil_total fell 3479 -> 33.8,
					// the entire aquifer discharging into a sea whose weight the kernel could not see.
					//
					// With the real term the sea holds its own groundwater down by its own head and needs no special
					// case — and a spring discharging into a FULL LAKE now correctly stops as well, which the static
					// test never covered, because a hollow filled by rain was never marked static.
					int nr = n % int(params.depth);
					float open_floor = params.core_radius + (float(nr) + 0.5) * params.cell_size;
					// The outlet's water depth is read RAW, not clamped to one cell. The water CA is compressible
					// (water_sphere3d.glsl: a cell above MAX_MASS is carrying the weight of a column above it), so
					// water[n] > 1 is precisely the signal that this outlet is under pressure from above — which is
					// the resistance a spring should feel. Clamping it to 1.0 threw that signal away and made every
					// drowned outlet look like a cell holding exactly one unit of standing water.
					float open_elev = open_floor + water[n] * params.cell_size;
					float exf_head = my_head - open_elev;
					if (exf_head > 0.0) {
						// DARCY, AS A GRADIENT. exf_head is a length; dividing by the cell size makes it the
						// dimensionless hydraulic gradient, so SPRING_CONDUCT is a flux per step in the same
						// currency as INFIL_RATE. It was NOT: SPRING_CONDUCT multiplied a head in WORLD units
						// (cell_size = 8*PLANET_SCALE), so 0.20 * a few metres always exceeded
						// remaining = MAX_FLOW_FRAC*s <= 0.21 and min() picked the stability cap EVERY time.
						// Every spring in the world ran flat out at the cap, head-proportional in name only.
						float exf = SPRING_CONDUCT * (exf_head / params.cell_size);
						// BACK-PRESSURE. A full outlet cannot accept water, and until now nothing said so: for the
						// INWARD neighbour the geometry makes the head positive by construction
						//     exf_head = table + (1 - w)*cell_size >= table > 0
						// so a regolith cell drained into the open cell beneath it every step however full that
						// cell already was. That one leg was 96% of the aquifer's measured drain, and 95% of its
						// outlets were roofed voids and carved channels rather than the sea. This mirrors the
						// receiver-headroom cap the Darcy leg above already applies to regolith receivers — the
						// same rule, finally applied on the side that needed it most.
						exf = min(exf, max(0.0, MAX_MASS - water[n]));
						exf = min(exf, remaining);
						send[base + uint(d)] = exf;
						remaining -= exf;
						dbg[dbase + DBG_SPRING_SENT] += exf;
						if (d == 0) { dbg[dbase + DBG_SPRING_DOWN] += exf; }
						else if (d == 5) { dbg[dbase + DBG_SPRING_UP] += exf; }
						else { dbg[dbase + DBG_SPRING_LAT] += exf; }
						if (water[n] >= 0.5) { dbg[dbase + DBG_SPRING_WET] += exf; }
						// How tall is the OPEN column standing above this outlet? 3+ open cells = a real water
						// body (sea/lake); rock within 2 = a cavity or a carved channel, i.e. confined.
						int oc = 0;
						int walk = nbr[uint(n) * 6u + 5u];
						for (int k = 0; k < 3; k++) {
							if (walk < 0 || solid[walk] != 0.0) { break; }
							oc++;
							walk = nbr[uint(walk) * 6u + 5u];
						}
						if (oc >= 3) { dbg[dbase + DBG_SPRING_FREECOL] += exf; }
						else { dbg[dbase + DBG_SPRING_CAPPED] += exf; }
					}
				}
			}
			// WATERLOGGED UP-SEEP: if the table is near-full (basin groundwater has nowhere lower to go), well the
			// surplus straight up into the open cell above → a perennial water-table lake sustained by the aquifer.
			//
			// THIS LEG IS A STAND-IN FOR HYDROSTATIC PRESSURE AND SHOULD EVENTUALLY BE DISSOLVED INTO ONE. The
			// spring loop above already visits the outward neighbour, so artesian flow ought to fall out of the
			// same head rule with no second leg — but it cannot, because head_of() clamps the table at one
			// cell_size, which makes exf_head against the cell ABOVE negative by construction (its floor is a
			// whole cell higher). Measured: spring_up is exactly 0.0000 at every horizon, and that is geometry,
			// not physics. Real artesian flow is driven by a confined aquifer's recharge area standing HIGHER
			// somewhere else — a pressure that is not a function of local water depth and that this substrate
			// does not yet carry. Until a real pressure channel exists, this leg approximates it.
			float surplus = s - CAPACITY * SEEP_THRESH;
			if (surplus > 0.0 && remaining > 0.0) {
				int up = nbr[base + 5u];
				if (up >= 0 && solid[up] == 0.0) {
					float seep = min(remaining, surplus * SEEP_RATE);
					// ...but it still cannot push water into a cell that is already full. The comment here used to
					// argue up-seep needed no such guard, "self-limiting because it only fires on the surplus above
					// SEEP_THRESH, which the head term prevents the seabed from ever reaching by drainage". That
					// was true only while the spring leg drained the seabed continuously; the moment that drain was
					// fixed the seabed saturated, crossed SEEP_THRESH, and this leg took over as the dominant sink
					// — measured seep_sent 6.03/step -> 29.50/step at field_step 50, the largest single leg in the
					// budget. Two legs each relying on the other to stay small is not self-limiting, it is a loop.
					seep = min(seep, max(0.0, MAX_MASS - water[up]));
					send[base + 5u] += seep;
					remaining -= seep;
					dbg[dbase + DBG_SEEP_SENT] += seep;
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
				dbg[dbase + DBG_INFIL_SENT] = infil;
			}
		}
		return;
	}

	// ---- PASS 1: apply — each cell adds inflow to its own store, subtracts its own outflow ----------------
	float own_out = send[base + 0u] + send[base + 1u] + send[base + 2u]
		+ send[base + 3u] + send[base + 4u] + send[base + 5u];
	float inflow = 0.0;
	// Accumulate the geothermal heat riding the groundwater: for each REGOLITH donor that sent water into this
	// cell, track (inflow_i * donor_temp_i) and inflow_i, so an open cell can arrive at the inflow-weighted
	// donor temperature. Donors are regolith-only (open cells only push water DOWN), so no open temp is ever
	// read here — and regolith cells never WRITE temp in this pass — making the neighbour temp reads race-free.
	float hot_flux = 0.0;
	float hot_mass = 0.0;
	// Probe: the same gather, split by DONOR TYPE, so "what regolith sent" can be compared against "what
	// arrived". from_reg = inflow whose donor is a regolith cell (Darcy, or a spring landing in open water);
	// from_open = inflow whose donor is an open cell (infiltration).
	float from_reg = 0.0;
	float from_open = 0.0;
	int nb; float sflow;
	nb = nbr[base + 0u]; if (nb >= 0) { sflow = send[uint(nb) * 6u + 5u]; inflow += sflow; if (regolith[nb] != 0.0) { from_reg += sflow; if (sflow > 0.0) { hot_flux += sflow * temp[nb]; hot_mass += sflow; } } else { from_open += sflow; } }  // down-nbr sent UP into me
	nb = nbr[base + 5u]; if (nb >= 0) { sflow = send[uint(nb) * 6u + 0u]; inflow += sflow; if (regolith[nb] != 0.0) { from_reg += sflow; if (sflow > 0.0) { hot_flux += sflow * temp[nb]; hot_mass += sflow; } } else { from_open += sflow; } }  // up-nbr sent DOWN into me
	nb = nbr[base + 1u]; if (nb >= 0) { sflow = send[uint(nb) * 6u + 2u]; inflow += sflow; if (regolith[nb] != 0.0) { from_reg += sflow; if (sflow > 0.0) { hot_flux += sflow * temp[nb]; hot_mass += sflow; } } else { from_open += sflow; } }
	nb = nbr[base + 2u]; if (nb >= 0) { sflow = send[uint(nb) * 6u + 1u]; inflow += sflow; if (regolith[nb] != 0.0) { from_reg += sflow; if (sflow > 0.0) { hot_flux += sflow * temp[nb]; hot_mass += sflow; } } else { from_open += sflow; } }
	nb = nbr[base + 3u]; if (nb >= 0) { sflow = send[uint(nb) * 6u + 4u]; inflow += sflow; if (regolith[nb] != 0.0) { from_reg += sflow; if (sflow > 0.0) { hot_flux += sflow * temp[nb]; hot_mass += sflow; } } else { from_open += sflow; } }
	nb = nbr[base + 4u]; if (nb >= 0) { sflow = send[uint(nb) * 6u + 3u]; inflow += sflow; if (regolith[nb] != 0.0) { from_reg += sflow; if (sflow > 0.0) { hot_flux += sflow * temp[nb]; hot_mass += sflow; } } else { from_open += sflow; } }

	// Probe: zero every APPLY leg first, so each branch below only has to fill in the ones it owns.
	dbg[dbase + DBG_REG_IN] = 0.0;      dbg[dbase + DBG_REG_OUT] = 0.0;
	dbg[dbase + DBG_OWN_OUT] = 0.0;     dbg[dbase + DBG_DARCY_RECV] = 0.0;
	dbg[dbase + DBG_INFIL_RECV] = 0.0;  dbg[dbase + DBG_CLAMP_GAIN] = 0.0;
	dbg[dbase + DBG_SPRING_RECV] = 0.0; dbg[dbase + DBG_OPEN_DROP] = 0.0;
	dbg[dbase + DBG_OPEN_FROM_OPEN] = 0.0; dbg[dbase + DBG_BEDROCK_IN] = 0.0;

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
		// Open cell: gains spring exfiltration from regolith neighbours, loses infiltration it sent down.
		water[g] = max(0.0, water[g] - own_out + inflow);
		dbg[dbase + DBG_SPRING_RECV] = from_reg;
		dbg[dbase + DBG_OPEN_FROM_OPEN] = from_open;
		dbg[dbase + DBG_OPEN_DROP] = soil_in[g];     // overwritten with 0 on the next line — a sink if nonzero
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
		// ...and INERT means it drops `inflow` on the floor. Nothing ever sends to bedrock on purpose (Darcy
		// targets regolith, springs target open, infiltration targets a regolith floor), so a nonzero reading
		// here can only come from a gather that read a slot its donor did not aim at this cell — the seam.
		dbg[dbase + DBG_BEDROCK_IN] = inflow;
	}
}
