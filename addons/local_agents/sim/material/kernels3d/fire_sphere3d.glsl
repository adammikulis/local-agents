#[compute]
#version 450

// CUBED-SPHERE FIRE / COMBUSTION. GATHER form (each cell sums the radiant heat thrown by its BURNING
// neighbours) so this single dispatch is order-independent: read the fire[] snapshot (fire_in), write own
// temp/fuel/o2/co2 in place, write next fire state to fire_out (ping-pong).
//
// WHAT COMBUSTION IS HERE. One reaction, and it is the one BioRecords already writes for respiration and
// decomposition, run fast and hot:
//
//     fuel(CH₂O) + O₂  ->  CO₂ + heat
//
// so ONE unit of fuel leaves the fuel channel, ONE unit of O₂ leaves the air, and ONE unit of CO₂ arrives —
// the same 1 C : 1 O₂ : 1 CO₂ identity BioRecords R15 (decompose) and R20 (respiration) obey, because it is
// the same oxidation. THIS KERNEL USED TO DESTROY HALF ITS CARBON: it debited fuel at BURN_RATE = 0.12 and
// credited CO₂ at CO2_PER_BURN = 0.06, so every second carbon atom that left the fuel arrived nowhere, and it
// drew O₂ at 0.06 against 0.12 of fuel, which is an oxidation that needs half the oxygen the reaction needs.
// Both were independent hand-written rates with nothing relating them. Now there is ONE rate, `burned`, and
// the three channels are debited and credited from it.
//
// AND IT USED TO PIN THE TEMPERATURE. `if (temp[g] < BURN_TEMP) { temp[g] = BURN_TEMP; }` with BURN_TEMP =
// 640 held every burning cell on the planet at one temperature — a thermostat, the same defect pattern as the
// ocean being held at 26 °C. It was visible in every run: SIM_REPORT's `ext_open_hot` maximum was exactly
// 640.0. A fire's temperature is a RESULT of three things, and now it is computed from them:
//   * the HEAT ITS COMBUSTION RELEASES — LAPhysical.HEAT_PER_KG_OXYGEN_J, the near-universal 13.1 MJ per kg
//     of O₂ consumed (Huggett 1980), times the oxygen a field unit stands for (AMBIENT_O2_DENSITY_KG_M3).
//     Anchoring on OXYGEN rather than on the fuel is deliberate: the substrate defines what `o2` = 1.0 is
//     (ambient air) and defines no bulk density for `fuel`, so this is the leg that can be measured rather
//     than invented.
//   * the HEAT CAPACITY OF WHAT IS BURNING — the cell's own air and water (RC_AIR / RC_WATER). Liquid water
//     holds 3500x the heat of the same volume of air, so a damp cell warms far less for the same reaction.
//     That is where "the temperature varies with what is burning" comes from, with no per-case code.
//   * the LOSS TO ITS SURROUNDINGS — the radiant term below, plus every thermal kernel that runs after this
//     one (conduction, radiative cooling to space, buoyant transport).
//
// FLAME SPREAD IS THAT SAME RADIATION, WITH A DONOR. The old ember terms (EMBER_HEAT 12, EMBER_UP 8,
// EMBER_WIND_GAIN, EMBER_MAX) added DEGREES to a neighbour and debited nobody — heat from nothing, four
// fitted constants of it. They are gone. A burning cell now radiates LAPhysical.FLAME_RADIATIVE_FRACTION of
// its own heat release (0.30, the measured radiative fraction of a wildland flame) and SUBTRACTS EXACTLY THAT
// from itself, so spread is a property of the release rather than a constant of its own. The geometry the old
// ember terms had is kept, because it is right: a flame throws to its four LATERAL neighbours and to the cell
// ABOVE it (fire climbs), never downward — five faces. The world-wind bias the box version applied is still
// dropped on the sphere, where the lateral slots point in varying world directions (the identical reasoning
// the o2/scent transport sphere ports use).
//
// The gather and the debit are exact counterparts: a cell credits `flame_radiance(fire_in[n])` for each open
// burning neighbour that throws at it, and debits `flame_radiance(fire_in[g])` for each open neighbour it
// throws at. Both sides read only the fire SNAPSHOT and the solid mask, so no cell reads a value another cell
// is writing, and the two sums are equal by the neighbour table's slot-opposite reciprocity (0<->5, 1<->2,
// 3<->4 — measured exhaustively at the shipped resolution: 0 non-reciprocal links of 407808). Note ENERGY is
// what transfers, not degrees: each side converts through ITS OWN heat capacity, so a flame beside a wet cell
// warms it barely while the flame still pays the full price.
//
// NEIGHBOUR slots: 0 = inward/radial-DOWN, 1-4 = LATERAL, 5 = outward/radial-UP; -1 = boundary -> skipped.
//
// EVERY OPEN CELL RUNS THE COMBUSTION TEST, EVERY STEP. Until 2026-08-03 binding 8 was a camera-relevance
// score and this kernel evaluated a per-cell update stride from it, so a fire far from the player burned on a
// slower clock than the same fire in front of them. Deleted — see MaterialSphereGPU3D.gd's header note.

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict buffer FireIn  { float fire_in[]; };
layout(set = 0, binding = 1, std430) restrict buffer FireOut { float fire_out[]; };
layout(set = 0, binding = 2, std430) restrict buffer Fuel    { float fuel[]; };
layout(set = 0, binding = 3, std430) restrict buffer Temp    { float temp[]; };
layout(set = 0, binding = 4, std430) restrict buffer Water   { float water[]; };
layout(set = 0, binding = 5, std430) restrict buffer Solid   { float solid[]; };
layout(set = 0, binding = 6, std430) restrict buffer O2      { float o2[]; };
layout(set = 0, binding = 7, std430) restrict buffer CO2     { float co2[]; };
layout(set = 0, binding = 15, std430) restrict readonly buffer Neigh { int nbr[]; };   // idx*6 + slot

layout(push_constant, std430) uniform Params {
	uint cell_count;
	uint pad0;
	uint pad1;
	uint pad2;
} params;

// --- PHYSICAL CONSTANTS (the authority is LAPhysical; scripts/check_physical_constants.sh gates these) -----
const float IGNITE_TEMP = 300.0;        // LAPhysical.VEGETATION_IGNITION_C — piloted ignition of dry cellulose.
                                        // Was 450.0, a number bound to nothing while the authority said 300.
const float HEAT_PER_KG_O2 = 1.31e7;    // LAPhysical.HEAT_PER_KG_OXYGEN_J
const float O2_UNIT_KG_M3 = 0.2731;     // LAPhysical.AMBIENT_O2_DENSITY_KG_M3 — what o2 = 1.0 stands for
const float RC_AIR = 1186.0;            // LAPhysical.VOL_HEAT_CAP_AIR_J_M3K
const float RC_WATER = 4.171e6;         // LAPhysical.VOL_HEAT_CAP_WATER_J_M3K
const float RADIATIVE_SHARE = 0.30;     // LAPhysical.FLAME_RADIATIVE_FRACTION

// Heat released per unit of fuel burned, per unit of cell volume [J/m³]. Derived, so it carries NO LAPhysical
// reference: the gate checks literals, and a product of two of them is not one. One unit of fuel takes one
// unit of O₂ with it (the reaction above), and one unit of O₂ is O2_UNIT_KG_M3 kilograms of oxygen, each of
// which releases HEAT_PER_KG_O2 joules.
const float HEAT_PER_UNIT_BURN = O2_UNIT_KG_M3 * HEAT_PER_KG_O2;   // 3.577e6 J/m³ per unit burned

// --- MODEL PARAMETERS (properties of this model, not of matter) -------------------------------------------
const float FUEL_MIN = 0.02;     // fuel below this cannot be lit
const float FIRE_MIN = 0.02;     // fire below this is out
const float FIRE_START = 0.4;    // intensity a fresh ignition starts at
const float FIRE_GROW = 0.3;     // intensity gained per step while fuel lasts
const float BURN_RATE = 0.12;    // fuel consumed per step at full intensity (a step is ~43 real seconds, so a
                                 // cell's fuel load burns out in minutes — a real surface-fire residence time)
const float WET_MAX = 0.05;      // standing water that drowns a flame (wet firebreak)
const float O2_MIN = 0.35;       // local O₂ below which a flame suffocates. A MODEL parameter, and a
                                 // questionable one: 0.35 of ambient is ~7 vol% O₂, while the measured
                                 // limiting oxygen concentration for flaming combustion of cellulosic solids
                                 // is ~15 vol% (~0.72 of ambient). Left alone here because raising it changes
                                 // the fire REGIME (how long a cell can burn before it needs fresh air), which
                                 // is a separate measurement from making the reaction conserve.
const float RADIATING_FACES = 5.0;   // the 4 lateral neighbours + the one above; a flame does not throw down

// The cell's volumetric heat capacity [J/m³/K]: a full cell of air plus whatever water it is carrying. The air
// term is a CONSTANT rather than (1 - w) * RC_AIR on purpose — these cells are not sealed boxes, air moves in
// and out freely and is not a conserved channel here, so treating it as a fixed background thermal mass is
// both the honest reading and the one that keeps the arithmetic exact when water arrives or leaves.
float heat_capacity(uint c) {
	return RC_AIR + max(water[c], 0.0) * RC_WATER;
}

// Energy one burning cell radiates ACROSS ONE FACE, per step [J/m³]. RADIATIVE_SHARE of the heat that cell's
// combustion is releasing, split over the faces it throws across. Depends only on the fire SNAPSHOT, so the
// receiver and the donor compute the identical number and the transfer is exact.
float flame_radiance(float f) {
	return RADIATIVE_SHARE * BURN_RATE * clamp(f, 0.0, 1.0) * HEAT_PER_UNIT_BURN / RADIATING_FACES;
}

void main() {
	uint g = gl_GlobalInvocationID.x;
	if (g >= params.cell_count) {
		return;
	}
	if (solid[g] != 0.0) {
		fire_out[g] = 0.0;
		return;
	}
	uint base = g * 6u;
	float f = fire_in[g];
	float cap = heat_capacity(g);
	float radiant = 0.0;            // net J/m³ this cell gains from flame radiation this step

	// 1) RADIANT GATHER — energy arriving from burning neighbours.
	//    4 LATERAL slots (1-4): symmetric spread; no world-wind bias on the sphere.
	for (int d = 0; d < 4; d++) {
		int n = nbr[base + 1u + uint(d)];
		if (n >= 0 && solid[n] == 0.0 && fire_in[n] > FIRE_MIN) {
			radiant += flame_radiance(fire_in[n]);
		}
	}
	//    The burning cell radially BELOW (slot 0) throws its plume up into this one — fire climbs.
	int nd = nbr[base + 0u];
	if (nd >= 0 && solid[nd] == 0.0 && fire_in[nd] > FIRE_MIN) {
		radiant += flame_radiance(fire_in[nd]);
	}

	// 2) RADIANT DEBIT — the exact counterpart: what THIS cell throws, if it is burning. The condition on each
	//    face is the one the receiver applies to this cell as a donor (open, burning), plus the receiver's own
	//    requirement that it is not solid, so the two sums are equal face for face.
	if (f > FIRE_MIN) {
		float out_face = flame_radiance(f);
		for (int d = 0; d < 4; d++) {
			int m = nbr[base + 1u + uint(d)];
			if (m >= 0 && solid[m] == 0.0) {
				radiant -= out_face;
			}
		}
		int up = nbr[base + 5u];
		if (up >= 0 && solid[up] == 0.0) {
			radiant -= out_face;                 // ...and the cell above gathers this as its plume term
		}
	}
	// Commit the radiant exchange BEFORE the phase test, so a cell heated past IGNITE_TEMP by its neighbours
	// this step can light this step (the ordering the ember gather had).
	if (radiant != 0.0) {
		temp[g] += radiant / cap;
	}

	// 3) PHASE — extinguish / burn / ignite (no neighbour reads).
	float fuel_i = fuel[g];
	float o2_i = o2[g];
	float fnew = 0.0;
	if (water[g] > WET_MAX || o2_i < O2_MIN) {
		fnew = 0.0;                                   // drowned OR suffocated
	} else if (f > FIRE_MIN) {
		if (fuel_i > 0.0) {
			// CARBON AND OXYGEN, ATOM FOR ATOM. What leaves the fuel arrives as CO₂; the oxidation takes one
			// O₂ with it. `burned` is capped by both reactants — a cell cannot burn fuel it does not have, and
			// cannot burn carbon there is no oxygen for.
			float burned = min(BURN_RATE * clamp(f, 0.0, 1.0), min(fuel_i, o2_i));
			fuel[g] = fuel_i - burned;
			o2[g] = o2_i - burned;
			co2[g] += burned;
			temp[g] += burned * HEAT_PER_UNIT_BURN / cap;   // the reaction's own enthalpy, nothing pinned
			fnew = (fuel[g] <= 0.0) ? 0.0 : min(1.0, f + FIRE_GROW);
		} else {
			fnew = 0.0;
		}
	} else if (fuel_i > FUEL_MIN && temp[g] >= IGNITE_TEMP) {
		fnew = FIRE_START;                            // IGNITION from any heat source
	}
	fire_out[g] = fnew;
}
