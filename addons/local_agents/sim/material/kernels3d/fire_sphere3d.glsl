#[compute]
#version 450

// CUBED-SPHERE FIRE / COMBUSTION. GATHER form (each cell sums the radiant heat thrown by its BURNING
// neighbours) so this single dispatch is order-independent: read the fire[] snapshot (fire_in), write own
// temp/fuel/o2/co2 in place, write next fire state to fire_out (ping-pong).
//
// WHAT COMBUSTION IS HERE. One reaction, and it is the one BioRecords already writes for respiration and
// decomposition, run fast and hot:
//
//     fuel(CH₂O) + O₂  ->  CO₂ + H₂O + heat,   and the nitrogen the fuel carried, which does not burn
//
// LAReactionBalance.composition() declares what a unit of `fuel` IS — {C 1, H 2, O 1, N 1/LITTER_C_TO_N},
// carbohydrate plus the nitrogen litter really carries at its measured C:N ratio — so the balance here is
// arithmetic, not opinion. Per unit burned the reactants bring C1 H2 O3 N0.05 (one fuel plus one O₂), and
// every atom of it is now placed: C1 O2 -> `co2`, H2 O1 -> `moisture`, N0.05 -> `fert`.
//
// UNTIL 2026-08-07 ONLY THE CARBON ARRIVED, and every unit burned destroyed 2 hydrogen, 1 oxygen and 1/20
// nitrogen. The kernel debited fuel and O₂ and credited CO₂ alone: combustion water and the ash's nitrogen
// were simply deleted. The load-time balance gate could not see it, because check_reaction_balance.sh
// validates LAReactionDefs records and this combustion is a standalone kernel that no record describes.
// (The carbon half was repaired earlier: fuel was debited at BURN_RATE 0.12 while CO₂ was credited at
// CO2_PER_BURN 0.06, two independent hand-written rates, so every second carbon atom arrived nowhere. There
// is ONE rate now, `burned`, and every channel is debited and credited from it.)
//
// THE TWO PRODUCT COEFFICIENTS ARE NOT CHOSEN HERE — they are the ones the reaction table already uses for
// this same oxidation, so combustion cannot drift away from decomposition:
//   * water   BioRecords.DECOMPOSE_WATER_YIELD = CO2_PER_DECOMPOSE = 1.0, "one H₂O per carbon oxidised".
//   * nitrogen BioRecords.FERT_PER_DECOMPOSE  = 1.0 / LITTER_C_TO_N,     the litter's own C:N ratio.
// R15 rots one unit of detritus to 1 CO₂ + 1 H₂O + 0.05 fert. Burning one unit of fuel does exactly that,
// faster and hotter, which is what this kernel's own header has always claimed it was.
//
// THE WATER IS VAPOUR, AND IT IS DELIBERATELY NOT CHARGED A LATENT HEAT. Combustion water leaves a flame far
// above its boiling point, so it belongs in `moisture` (the air's suspended H₂O) and not in `water` (liquid
// standing in the cell). It also costs nothing extra to make: HEAT_PER_KG_OXYGEN_J below is Huggett's
// oxygen-consumption figure, which is measured on the NET heat of combustion — the product water is already
// counted as vapour in it. Debiting a latent heat here would subtract the same energy twice. Once that vapour
// drifts into cold air the atmosphere pass condenses it and snowice can freeze it out, exactly like any other
// water in the sky, with no per-case code.
//
// THE NITROGEN IS A LUMPED APPROXIMATION. Say what it approximates and what it omits: a real wildfire
// VOLATILISES most fuel nitrogen — to N₂, NO/NO₂ and NH₃ — and leaves the remainder as mineral N (largely
// NH₄⁺) in the ash. This substrate has no NOx or N₂ channel, and `fert` is its only plant-available mineral
// nitrogen, so ALL of the fuel's N is credited there. What that gets right is that the nitrogen is conserved
// and lands on the ground the fire burned over, which is why a burn is followed by a flush of growth. What it
// omits is the gaseous share, so this OVERSTATES post-fire soil nitrogen and understates the atmospheric
// loss. The honest alternative available today was to keep deleting it, which is not an approximation.
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
// The two products the reaction used to destroy. Both are mutated IN PLACE on the half whose value survives
// this step — which is a DIFFERENT half for each, and FireDustPass.gd's set carries the reason:
//   moisture -> the BACK half, the one AtmospherePass finished writing before this pass ran;
//   fert     -> the LIVE half, because EcoSurfacePass runs AFTER this pass and its scent_fert kernel
//               ASSIGNS fert[back] from fert[live], so a credit written to back would be overwritten.
layout(set = 0, binding = 8, std430) restrict buffer Moisture { float moisture[]; };
layout(set = 0, binding = 9, std430) restrict buffer Fert     { float fert[]; };
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
const float LITTER_C_TO_N = 20.0;       // LAPhysical.LITTER_C_TO_N — the measured mass C:N of leaf litter,
                                        // the same ratio LAReactionBalance uses to say what `fuel` contains
                                        // and BioRecords uses to release nitrogen from decomposition
const float LOC_O2_MOLE_FRAC = 0.15;    // LAPhysical.LIMITING_OXYGEN_CONCENTRATION_FRAC
const float AIR_O2_MOLE_FRAC = 0.20946; // LAPhysical.AIR_MOLE_FRAC_O2

// Heat released per unit of fuel burned, per unit of cell volume [J/m³]. Derived, so it carries NO LAPhysical
// reference: the gate checks literals, and a product of two of them is not one. One unit of fuel takes one
// unit of O₂ with it (the reaction above), and one unit of O₂ is O2_UNIT_KG_M3 kilograms of oxygen, each of
// which releases HEAT_PER_KG_O2 joules.
const float HEAT_PER_UNIT_BURN = O2_UNIT_KG_M3 * HEAT_PER_KG_O2;   // 3.577e6 J/m³ per unit burned

// THE OXYGEN A FLAME NEEDS. A measured property of the fuel and the oxidiser, not a difficulty setting:
// below the limiting oxygen concentration a flame goes out however hot it is, which is why a fire in a
// sealed room self-extinguishes long before the oxygen is gone and why an anoxic planet cannot burn.
// Derived from the two authority constants above rather than written down, so the gate binds BOTH legs and
// neither can drift: the `o2` channel is in units of modern ambient air, so the measured mole fraction is
// divided by air's own to become a channel value. 0.15 / 0.20946 = 0.716.
//
// It was 0.35 — about 7 vol% O₂, half the real threshold — so a cell burned roughly twice the oxygen a real
// flame can before suffocating. Its own comment said exactly that and left the value in place.
const float O2_MIN = LOC_O2_MOLE_FRAC / AIR_O2_MOLE_FRAC;

// Nitrogen released per unit of fuel burned, off the fuel's declared composition. The same figure
// BioRecords hands R15, because rotting and burning oxidise the same carbon out of the same matter.
//
// IT IS MOLAR, AND `1.0 / LITTER_C_TO_N` WAS NOT. *(Fixed 2026-08-08.)* LITTER_C_TO_N is a ratio of MASSES —
// 20 kg of carbon per kg of nitrogen — and spending it as a mole count in a stoichiometric coefficient
// overstates the nitrogen by 16%. Per mole of CH₂O the litter carries CARBON_MOLAR_MASS / 20 kilograms of
// nitrogen, i.e. that divided by NITROGEN_MOLAR_MASS moles. `fert` shares organic matter's molar basis, so
// this needs no unit conversion on top of it — only the right number.
const float C_MOLAR_MASS = 0.0120110;      // LAPhysical.MOLAR_MASS_CARBON_KG_MOL
const float N_MOLAR_MASS = 0.0140067;      // LAPhysical.MOLAR_MASS_NITROGEN_KG_MOL
const float N_PER_FUEL = (C_MOLAR_MASS / LITTER_C_TO_N) / N_MOLAR_MASS;

// --- THE UNIT BRIDGE FROM A GAS CHANNEL TO A WATER CHANNEL -------------------------------------------------
// `burned` is an amount of the O₂ channel, whose unit is the O₂ in a cell of ambient air. `moisture` is a
// FRACTION OF A CELL FULL OF LIQUID WATER. Those are not the same amount of substance and they are nowhere
// near it: 8.535 mol/m³ against 55343, a factor of 6484. So `moisture += burned` for a 1:1 molar reaction
// emitted 6484 times the water combustion actually makes — enough to put a burning cell three orders of
// magnitude past saturation in one step. It is the same defect the biological records carried until the
// balance gate was taught mol_per_unit(), and combustion is a standalone kernel, so no gate can catch this
// one. It has to be right here.
const float O2_MOLAR_MASS = 0.0319988;     // LAPhysical.MOLAR_MASS_O2_KG_MOL
const float WATER_MOLAR_MASS = 0.018015;   // LAPhysical.MOLAR_MASS_WATER_KG_MOL
const float WATER_DENSITY = 997.0;         // LAPhysical.WATER_DENSITY_KG_M3
const float GAS_MOL_PER_UNIT = O2_UNIT_KG_M3 / O2_MOLAR_MASS;
const float WATER_MOL_PER_UNIT = WATER_DENSITY / WATER_MOLAR_MASS;
const float MOISTURE_PER_GAS_UNIT = GAS_MOL_PER_UNIT / WATER_MOL_PER_UNIT;

// --- MODEL PARAMETERS (properties of this model, not of matter) -------------------------------------------
const float FUEL_MIN = 0.02;     // fuel below this cannot be lit
const float FIRE_MIN = 0.02;     // fire below this is out
const float FIRE_START = 0.4;    // intensity a fresh ignition starts at
const float FIRE_GROW = 0.3;     // intensity gained per step while fuel lasts
const float BURN_RATE = 0.12;    // fuel consumed per step at full intensity (a step is ~43 real seconds, so a
                                 // cell's fuel load burns out in minutes — a real surface-fire residence time)
const float WET_MAX = 0.05;      // standing water that drowns a flame (wet firebreak)
const float RADIATING_FACES = 5.0;   // the 4 lateral neighbours + the one above; a flame does not throw down

// The cell's volumetric heat capacity [J/m³/K]: a full cell of air plus whatever water it is carrying. The air
// term is a CONSTANT rather than (1 - w) * RC_AIR on purpose — these cells are not sealed boxes, air moves in
// and out freely and is not a conserved channel here, so treating it as a fixed background thermal mass is
// both the honest reading and the one that keeps the arithmetic exact when water arrives or leaves.
//
// IS THIS WHY FIRES RAN AT 5682 C? NO, AND THE ARITHMETIC RULES IT OUT. Commit 7905991 measured ext_open_hot
// at 2544.8 / 2051.1 / 5682.7 C against a real wildfire's 800-1200 C, and named three suspects: this heat
// capacity, the suffocation threshold, or something else. Sizing them:
//   * Burning one whole unit of O₂ in a dry cell raises it HEAT_PER_UNIT_BURN / RC_AIR = 3.577e6 / 1186 =
//     3016 K. That is the constant-cp adiabatic stoichiometric rise, ~35% above a real wood/air flame's
//     ~2200 K because cp climbs with temperature and the products dissociate. Expected, and not a blunder.
//   * For THIS function to be the cause, `cap` would have to be 1186 * (5682-300)/(1200-300) = 7092 J/m³/K,
//     i.e. 6.0x the air term. The one mass genuinely missing from it is the fuel itself: one unit of fuel is
//     one unit of O₂ by the reaction above, so 0.2731 kg/m³ of O₂ carries 0.256 kg/m³ of CH₂O, which at dry
//     wood's ~1500 J/kg/K is ~400 J/m³/K — a 34% addition, not a 500% one. (Rock is not a candidate: this
//     kernel returns early for solid cells, so a burning cell contains no rock, only sits beside it.)
//   * The suffocation threshold IS a real 2x error and is the one fixed here. A cell can only draw its O₂
//     down to O2_MIN before the flame dies, so one charge of ambient air delivers (1 - O2_MIN) * 3016 K:
//     1961 K at the old 0.35, and 857 K at the measured 0.716. That is the leg that was a wrong physical
//     constant, and correcting it cuts what any single charge of air can deliver by 2.3x.
//   * WHAT REMAINS, and it is not in this file: a cell that has suffocated is refilled toward ambient by
//     gas_sky/GasWind and burns again, while nothing carries its hot gas away. A real flame is an open
//     buoyant plume — it entrains fresh air AND loses the heated products, which is most of why a measured
//     wildfire sits far below its adiabatic temperature. Here only the first half happens, so a fuelled cell
//     can ratchet past one charge's worth of heat. That is thermal transport (ThermalPass / GasWindPass),
//     not combustion stoichiometry.
// NOT RE-MEASURED, because combustion is currently unreachable: five run arms (--planet-only, --no-fauna,
// and --no-fauna with --auto-lightning / --auto-meteor / --auto-volcano, 600 frames, --fast=8, seed 4242)
// all report fires 0 / fire_cells 0 / fire_peak 0.0 with ext_open_hot never above 330 C. See the track report.
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
			// EVERY ATOM PLACED, not just the carbon. Reactants C1 H2 O3 N0.05 per unit burned; products
			// C1 O2 as CO₂, H2 O1 as water vapour, N0.05 as mineral nitrogen in the ash. `burned` is capped
			// by both reactants — a cell cannot burn fuel it does not have, nor carbon there is no oxygen for.
			float burned = min(BURN_RATE * clamp(f, 0.0, 1.0), min(fuel_i, o2_i));
			fuel[g] = fuel_i - burned;
			o2[g] = o2_i - burned;
			co2[g] += burned;                     // C1 O2
			moisture[g] += burned * MOISTURE_PER_GAS_UNIT;   // H2 O1 — as vapour, in the water channel's unit
			fert[g] += burned * N_PER_FUEL;       // N — what the litter carried, back to the ground it burned
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
