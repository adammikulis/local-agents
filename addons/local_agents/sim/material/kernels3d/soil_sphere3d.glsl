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
// floor is what stops the naive "all groundwater sinks to the core"; CAPILLARY RETENTION (k_rel/RESIDUAL below)
// is what makes the aquifer surface-following, by stopping gravity drainage at field capacity instead of
// letting every shell bleed into the one beneath it.
//
// One 2-pass GATHER over the shared `send` scratch (each send = mass moved in a direction; the receiver adds it
// to soil if it is regolith, to surface water if it is open — the soil<->water phase change at the boundary is
// mass-conserving). Race-free: each cell writes only its own soil/water. Elevation is computed in-kernel from
// r = gid % depth, so no elevation buffer is needed. NEIGHBOUR slots: 0=inward/down … 5=outward/up; -1=boundary.
//
// --- WATER CARRIES ITS ENTHALPY, AND THE ROCK PAYS FOR THE SPRING -------------------------------------------
// Moving water moves HEAT. Until 2026-08-08 only half of that was booked: a spring landing in an open cell
// WARMED it toward the donor rock's temperature, and no write anywhere cooled anything. The comment at the
// receiver argued the case instead of paying it — "the parcel's heat is the rock's, continuously replenished by
// conduction from the core/magma" — which is a description of an INFINITE heat source. 1084 hot-spring cells,
// 122 of them boiling, peaking at 263 C, all of it heat from nothing.
//
// The leak is not where it looks. Removing water from a cell AT THAT CELL'S OWN TEMPERATURE is isothermal: the
// cell loses m*rho_c_w*T of energy and m*rho_c_w of heat capacity, so E/C is unchanged and the export needs no
// temperature write at all. What was missing is the OTHER end of the same cycle — the cold rain infiltrating
// back INTO the rock was heated to the rock's temperature for free, every step, forever. That is the term that
// makes the aquifer an infinite reservoir, and it is worth m*rho_c_w*(T_rock - T_surface) per unit recharge.
// A real geothermal field cools exactly this way: cold recharge sweeps the stored heat out of the rock.
//
// So both mixes are now capacity-weighted enthalpy mixes, T = (C_here*T_here + C_in*T_in)/(C_here + C_in),
// which is what conserves energy across a mass transfer — mix() on TEMPERATURE alone moves degrees without
// moving joules.
//
// RACE-FREEDOM, and it is the reason the two halves live in different passes.
//   * PASS 1 already reads `temp[nb]` at REGOLITH donors to warm an open receiver. That read is safe only
//     because pass 1's temp writes are own-cell AND confined to NON-REGOLITH OPEN cells (the `regolith[g]`
//     branch writes no temp). Read set {regolith} and write set {non-regolith open} are disjoint. Adding a
//     regolith temp write to pass 1 would break exactly that, because many open cells can share one donor.
//   * PASS 0 READS NO TEMPERATURE AT ALL, so it is free. The recharge debit goes there, and it is safe by the
//     RADIAL BIJECTION `nbr[c*6+0] == c-1` (SphereGrid.gd:178): a regolith cell is the DOWN-neighbour of
//     EXACTLY ONE cell, so the open cell above it is its only possible writer. Lateral slots hold same-`r`
//     cells and can never collide with a same-column r-1 cell. Same argument ReactionDefs.BEDROCK_BELOW and
//     erosion_pickup_sphere3d.glsl already rest on. The infiltration branch runs only for cells that are open
//     AND NOT regolith (the regolith branch returns first), so no thread ever reads a temperature another
//     thread is writing.
//   * WHAT IS STILL NOT PAID: the regolith->regolith DARCY leg. Water moving between two rock cells arrives
//     with no enthalpy and is silently re-heated to the receiver's temperature, worth m*rho_c_w*(T_recv-T_donor)
//     per link. Booking it needs the receiver to write its own temp in pass 1 while other threads read it as a
//     donor, which is the race above; there is no bijection for it (a regolith cell has up to six Darcy donors)
//     and the `send` scratch has no spare slot to carry the donor temperature across the barrier. It is
//     constructible with ONE extra dispatch or ONE extra float per cell, both of which live outside this file.
//     It is a smaller term than the recharge — adjacent rock cells sit one geotherm step apart, not 100-300 C
//     apart — but it is not zero and it is not fixed.

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict buffer Water { float water[]; };            // settled surface water (in place)
layout(set = 0, binding = 1, std430) restrict readonly buffer Solid { float solid[]; };
layout(set = 0, binding = 2, std430) restrict readonly buffer Static { float static_cells[]; };
layout(set = 0, binding = 3, std430) restrict buffer Send { float send[]; };                // idx*6 + dir (shared scratch)
layout(set = 0, binding = 4, std430) restrict readonly buffer SoilIn { float soil_in[]; };  // live soil (last step)
layout(set = 0, binding = 5, std430) restrict writeonly buffer SoilOut { float soil_out[]; };
layout(set = 0, binding = 6, std430) restrict readonly buffer Regolith { float regolith[]; }; // 1 = permeable aquifer rock
layout(set = 0, binding = 7, std430) restrict buffer Temp { float temp[]; };                // POST-thermal temp, carry-heat in place
layout(set = 0, binding = 8, std430) restrict readonly buffer Grain { float grain[]; };     // representative grain diameter, metres
layout(set = 0, binding = 9, std430) restrict buffer SoilDbg { float dbg[]; };              // per-leg budget probe
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
// `CONDUCT = 0.35` was ONE saturated hydraulic conductivity for every cell of regolith on the planet. Read as
// a real flux — conduct = K * step_seconds / shell_metres — it means K = 4.05 m/s, which is twenty-six times
// more permeable than the coarsest natural gravel and roughly a thousand million times a silt. Real K spans
// twelve orders of magnitude (Freeze & Cherry 1979 Table 2.2) and it does so because PORE GEOMETRY varies.
//
// So K is computed, per cell, from the two things pore geometry is made of — porosity and grain size — by the
// Kozeny-Carman relation. No material table, no type enum: one relation, two continuous fields.
//   POROSITY closes with burial (Athy 1930): phi(z) = phi_0 * exp(-z / z_c). Over this planet's 2 km
//   circulating zone that takes 0.40 at the ground surface to 0.20 on the bedrock floor, which is what makes
//   the water table surface-following rather than a uniform sponge.
//   GRAIN SIZE is the `grain` channel, seeded once from where the material sits — coarse valley-fill alluvium
//   in the basins, fine residual saprolite on the uplands (see LAMaterialField3D._compute_grain).
// The same porosity is the cell's storage CAPACITY, because that is what porosity means. It used to be a
// separate constant 0.60, above the porosity of every real granular material, while the conductivity was
// computed as if from a different rock.
const float KOZENY_C = 180.0;              // LAPhysical.KOZENY_CARMAN_C
const float GRAVITY = 9.81;                // LAPhysical.GRAVITY_M_S2
const float WATER_VISCOSITY = 1.002e-3;    // LAPhysical.WATER_DYNAMIC_VISCOSITY_PA_S
const float RHO_WATER = 997.0;             // LAPhysical.WATER_DENSITY_KG_M3
const float SURFACE_POROSITY = 0.40;       // LAPhysical.REGOLITH_SURFACE_POROSITY
const float COMPACTION_LEN_M = 2500.0;     // LAPhysical.COMPACTION_LENGTH_M
const int REG_CELLS = 4;                   // MUST match MaterialField3D.REGOLITH_CELLS

// VOLUMETRIC HEAT CAPACITIES — what it costs to warm a cubic metre of each thing by one degree. These are the
// currency of every enthalpy mix below: water carries 1.7x rock's rho*c per unit volume and 3500x air's, which
// is why a trickle of groundwater can dominate the temperature of the cell it lands in. Same three values, same
// names, as heat3d_cool_sphere3d.glsl and heat3d_solar_sphere3d.glsl — one quantity, one number.
const float RC_AIR   = 1185.9;    // LAPhysical.VOL_HEAT_CAP_AIR_J_M3K
const float RC_ROCK  = 2.436e6;   // LAPhysical.VOL_HEAT_CAP_ROCK_J_M3K
const float RC_WATER = 4171448.0; // LAPhysical.VOL_HEAT_CAP_WATER_J_M3K

// A REGOLITH cell's heat capacity, from what it is actually made of: a solid matrix of fraction (1 - phi), pore
// water `s`, and air in the pore space that is left. `heat3d_cool_sphere3d.glsl:94 rc_of()` returns a flat
// RC_ROCK for every solid cell, which throws the groundwater's thermal mass away — a saturated cell at phi 0.4
// is 3.13e6, 28% above 2.436e6. This kernel is the one place that has phi and s in hand, so it uses them; the
// divergence is reported rather than papered over.
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
	int walk = nbr[uint(c) * 6u + 5u];
	for (int k = 0; k < REG_CELLS; k++) {
		if (walk < 0 || regolith[walk] == 0.0) {
			break;
		}
		d++;
		walk = nbr[uint(walk) * 6u + 5u];
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
// UNSATURATED CONDUCTIVITY — WHY A DRY CELL MUST NOT DRAIN AT THE SATURATED RATE.
// Porous media do not conduct at K_sat when their pores are not full: K(theta) = K_sat * k_r(S_e), and k_r
// collapses by orders of magnitude as the pores empty, because what is left clings to grain surfaces in films
// too thin and too disconnected to carry flow. Below the RESIDUAL saturation, capillary (matric) suction holds
// the water against gravity indefinitely — that is what FIELD CAPACITY means, and it is why a soil profile a
// week after rain is still moist near the surface instead of having drained to the bedrock. In a real profile
// the root zone is the WETTEST part after rain.
//
// THIS TERM WAS ENTIRELY ABSENT. CONDUCT was applied flat at every saturation, so every regolith cell went on
// draining downward at full saturated conductivity all the way to zero and nothing ever held water in the
// vadose zone. Measured on 0.4-dev @ e7f543d at field_step 799, mean saturation by shell from the ground
// surface inward: [0.0026, 0.0048, 0.0345, 0.1686] — the root zone was the DRIEST cell in the column, by a
// factor of 65, and the whole aquifer had bled into the bedrock floor and out to sea (soil_total 3997 -> 421).
// Slot-order greed (fixed below) accounted for only ~11% of that; this is the mechanism.
const float RESIDUAL = 0.30;          // fraction of CAPACITY held against gravity by capillarity. Field capacity
                                      // over porosity for real soils: sand 0.091/0.437 = 0.21, sandy loam
                                      // 0.207/0.453 = 0.46, loam 0.27/0.463 = 0.58 (Rawls, Brakensiek & Saxton
                                      // 1982, USDA texture class means). Weathered regolith is coarse, so this
                                      // sits at the sand / sandy-loam end.
// Irmay (1954), the cubic law for granular porous media: k_r = S_e^3. (Brooks & Corey's k_r = S_e^(3+2/lambda)
// and Mualem-van Genuchten are the same shape with a texture-dependent exponent; the cubic is the coarse-media
// limit and is the least assuming choice for regolith.)
float k_rel(float s, float cap) {
	float se = clamp((s / max(cap, 1e-6) - RESIDUAL) / (1.0 - RESIDUAL), 0.0, 1.0);
	return se * se * se;
}
// SPRINGS emerge where the water-table HEAD rises above an open neighbour's floor — i.e. at VALLEY WALLS where
// the regolith meets open ground laterally, NOT on flat ground (whose only open neighbour is straight up, which
// the table can't exceed unless brim-full). This auto-concentrates discharge at valleys and self-limits: seeping
// drains the local table, so a spring only SUSTAINS where groundwater keeps CONVERGING (a real valley). No fixed
// threshold, no blanket baseflow (which floods the whole surface). SPRING_CONDUCT = discharge per step at UNIT
// HYDRAULIC GRADIENT (head difference divided by cell size), i.e. the same dimensionless currency as INFIL_RATE
// below — NOT per unit head in world units, which is what it used to be and why every spring pinned at the cap.
// SPRING_CONDUCT is GONE. Exfiltration at a seepage face is Darcy flow through the same rock as every other
// leg, so it takes the same computed conductivity — a separate 0.20 was a second, unrelated permeability for
// the same cell. One rock, one K.
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

// Which leg a per-slot desired flow belongs to, so the budget-sharing loop can attribute it to the right probe
// slot after scaling. (The up-seep leg is tracked separately — it shares slot 5 with a possible spring.)
const int LEG_NONE = 0;
const int LEG_DARCY = 1;
const int LEG_SPRING = 2;

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
			float my_cap = porosity_of(idx);
			float my_conduct = conduct_of(idx, my_cap);
			float my_head = head_of(idx, s, my_cap);
			// The DONOR's unsaturated conductivity gates every leg that moves water THROUGH the rock — Darcy and
			// the spring seepage face alike. Upstream weighting is the standard for unsaturated flow: the cell
			// water is leaving is the one whose pore network has to carry it. A cell at or below field capacity
			// has k_rel == 0 and conducts nothing, which is what stops the vadose zone bleeding dry.
			float kr = k_rel(s, my_cap);
			// PROPORTIONAL ALLOCATION, NOT SLOT-ORDER GREED. Every direction's DESIRED flow is computed first,
			// then the step's stability budget is shared among them by ONE scale factor, so no direction can be
			// starved by where it happens to sit in the neighbour table.
			//
			// What this replaces: the loop used to spend `remaining = s * MAX_FLOW_FRAC` greedily in slot order
			// and `break` when it ran out. Slot 0 is the INWARD neighbour, a full cell_size lower, and head_of()
			// caps a cell's water table at exactly one cell_size — so the downward gradient is positive by
			// construction unless the cell below is brim-full, and it is ~1.0 whenever the two hold similar
			// water. Every other leg competes against that with a gradient of (s_me - s_them)/CAPACITY, which is
			// near zero on a level table. The budget therefore went straight down in every cell every step, and
			// the `break` meant lateral Darcy and the spring/exfiltration legs often never ran at all.
			//
			// Scaling every leg by ONE factor is the standard mass-limited redistribution for an explicit
			// multi-direction flow solver: the uncapped physics prescribes the RATIOS between the fluxes, and
			// uniform scaling is the only limiter that preserves them. Exactly conserving — pass 1 debits the
			// same `send` slots it credits, and the scaled total is <= MAX_FLOW_FRAC * s < s, so a cell can
			// never over-draw and the apply clamp still never fires. Same rule reactions_sphere3d.glsl's
			// root_soil_draw() already uses to split a root's draw across its rooting column.
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
						// UPSTREAM weighting: the DONOR's rock is the one the water has to move through.
						float flow = min(my_conduct * kr * grad, max(0.0, n_cap - soil_in[n]));
						if (flow > 0.0) {
							want[d] = flow;
							leg[d] = LEG_DARCY;
							total_want += flow;
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
						float exf = my_conduct * kr * (exf_head / params.cell_size);
						// BACK-PRESSURE. A full outlet cannot accept water, and until now nothing said so: for the
						// INWARD neighbour the geometry makes the head positive by construction
						//     exf_head = table + (1 - w)*cell_size >= table > 0
						// so a regolith cell drained into the open cell beneath it every step however full that
						// cell already was. That one leg was 96% of the aquifer's measured drain, and 95% of its
						// outlets were roofed voids and carved channels rather than the sea. This mirrors the
						// receiver-headroom cap the Darcy leg above already applies to regolith receivers — the
						// same rule, finally applied on the side that needed it most.
						exf = min(exf, max(0.0, MAX_MASS - water[n]));
						if (exf > 0.0) {
							want[d] = exf;
							leg[d] = LEG_SPRING;
							total_want += exf;
						}
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
			//
			// Deliberately NOT gated by k_rel: it stands in for a pressure the substrate does not carry, not for
			// conduction through partly-filled pores, and it only fires above SEEP_THRESH * CAPACITY where
			// k_rel is 0.63-1.0 anyway. Gating it would be applying a correction to a placeholder.
			float seep_want = 0.0;
			float surplus = s - my_cap * SEEP_THRESH;
			if (surplus > 0.0) {
				int up = nbr[base + 5u];
				if (up >= 0 && solid[up] == 0.0) {
					// ...but it still cannot push water into a cell that is already full. The comment here used to
					// argue up-seep needed no such guard, "self-limiting because it only fires on the surplus above
					// SEEP_THRESH, which the head term prevents the seabed from ever reaching by drainage". That
					// was true only while the spring leg drained the seabed continuously; the moment that drain was
					// fixed the seabed saturated, crossed SEEP_THRESH, and this leg took over as the dominant sink
					// — measured seep_sent 6.03/step -> 29.50/step at field_step 50, the largest single leg in the
					// budget. Two legs each relying on the other to stay small is not self-limiting, it is a loop.
					// The headroom left is the outlet's, MINUS whatever the spring leg already aimed at the SAME
					// open cell through slot 5 — two legs sharing one outlet must share its capacity, which the
					// old pair of independent min()s did not enforce.
					seep_want = min(surplus * SEEP_RATE, max(0.0, MAX_MASS - water[up] - want[5]));
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
				int walk = nbr[uint(n) * 6u + 5u];
				for (int k = 0; k < 3; k++) {
					if (walk < 0 || solid[walk] != 0.0) { break; }
					oc++;
					walk = nbr[uint(walk) * 6u + 5u];
				}
				if (oc >= 3) { dbg[dbase + DBG_SPRING_FREECOL] += f; }
				else { dbg[dbase + DBG_SPRING_CAPPED] += f; }
			}
			float seep = seep_want * scale;
			if (seep > 0.0) {
				send[base + 5u] += seep;                   // += : slot 5 may already carry a scaled spring flow
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
			int ib = nbr[base + 0u];                       // inward / down
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
				send[base + 0u] = infil;
				dbg[dbase + DBG_INFIL_SENT] = infil;
				// COLD RECHARGE COOLS THE ROCK IT SOAKS INTO — the debit that pays for every hot spring.
				//
				// This surface water leaves at THIS cell's temperature, which is isothermal for this cell (it
				// loses infil*RC_WATER of energy and infil*RC_WATER of capacity together), so nothing is written
				// here. It ARRIVES in the rock below as a parcel that is 100-300 C colder than the rock, and the
				// rock has to warm it out of its own stored heat. Before this, the parcel was simply assigned the
				// rock's temperature on arrival and the rock kept its own, which made the aquifer an infinite
				// geothermal reservoir; a real one depletes exactly here, which is why hot springs need deep
				// circulation or magma rather than a warm shallow soil.
				//
				// Capacity-weighted mix, which is the only form that conserves energy across a mass transfer.
				// The capacity used is the rock cell's PRE-STEP one: its own outflow this step is computed by
				// its own thread with no barrier between us, so it is not readable here. That overstates C by at
				// most MAX_FLOW_FRAC * s * RC_WATER, which UNDER-cools — it can only leave the old leak partly
				// open, never invent a new one in the other direction.
				//
				// Race-free by the radial bijection: `ib` is `g - 1`, so this thread is the only one that can
				// address temp[ib] (see the header). Pass 0 reads no other cell's temperature.
				float c_in = infil * RC_WATER;
				float c_rock = reg_heat_cap(ib_cap, soil_in[ib]);
				temp[ib] = (c_rock * temp[ib] + c_in * temp[g]) / (c_rock + c_in);
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
	//
	// THAT DISJOINTNESS IS LOAD-BEARING, NOT INCIDENTAL. Read set {regolith}, write set {non-regolith open}. A
	// regolith cell has up to six donors, so any temp write on the regolith side of THIS pass is a genuine race
	// — which is why the recharge debit is in pass 0 under the radial bijection instead. Do not "just add" a
	// regolith temp write here; see the header for what it would take to do the Darcy leg properly.
	// The values read are post-pass-0, so the rock has already been cooled by this step's recharge before its
	// discharge is drawn from it. That is the right order: you cannot spend the same joule twice.
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
		// CARRY GEOTHERMAL HEAT: groundwater surfacing from regolith arrives at the donor rock's temperature.
		// Water sourced from deep/near-magma regolith surfaces HOT → the boiling/evap kernel steams it (a hot
		// spring / fumarole); water from cool shallow regolith surfaces cool → an ordinary spring. Nothing is
		// scripted: which springs are hot falls out of the head gradient meeting the geothermal heat field.
		//
		// The DONOR needs no write. Its water left at its own temperature, so it lost energy and heat capacity
		// in the same ratio and its temperature is unchanged — the debit for that heat is charged where the
		// cycle closes, at the recharge in pass 0 (see the header). What USED to be missing here is different
		// and is fixed below.
		//
		// TWO CORRECTIONS, both of which made heat appear.
		// 1. `mix(temp[g], donor_t, hot_mass/wnew)` interpolates TEMPERATURE on a MASS fraction, so it moves
		//    degrees without moving joules whenever the two parcels differ in heat capacity. The energy-
		//    conserving form is T = (C_here*T_here + C_in*T_in) / (C_here + C_in). For a cell that is pure
		//    water the two agree; they diverge for a thin film, where the cell is mostly air.
		// 2. `if (donor_t > temp[g])` made the transfer ONE-WAY: cold groundwater discharging into a warmer
		//    pool was discarded rather than cooling it. Advection is signed — a cold spring cools what it runs
		//    into, and a ratchet that only ever adds heat is a heat source. The guard is gone.
		// The `wnew > 1.0e-6` guard went with it: C_here + C_in is strictly positive whenever hot_mass > 0
		// because air alone carries RC_AIR, so there is nothing left to divide by zero.
		if (hot_mass > 0.0) {
			float donor_t = hot_flux / hot_mass;
			// What was already standing here, at temp[g]: the post-outflow water minus the parcel that just
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
