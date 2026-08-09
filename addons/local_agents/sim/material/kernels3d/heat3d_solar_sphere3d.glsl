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
// WHICH CELLS EXCHANGE RADIATION WITH SPACE. *(Rewritten 2026-08-03. The old rule was
// `surface = top_of_atm || ground_hug` with `top_of_atm = (up < 0) || solid[up] != 0` and
// `ground_hug = down >= 0 && solid[down] != 0`, and it was wrong in four separate ways at once — see the
// COLUMN SHORTWAVE BUDGET block. Each cell still touches only ITSELF, so it is still race-free.)*
//
// A cell trades radiation with the sky only if the radial path outward is CLEAR, and each column's incoming
// beam is spent exactly once. Three roles, and a cell may hold two of them at a mountain top:
//   * TOP OF ATMOSPHERE — the outermost open cell (slot 5 is -1, real space). It absorbs the share of the beam
//     the AIR COLUMN takes and radiates as a near-blackbody, because there is nothing overhead to intercept it.
//   * MATERIAL SURFACE — the cell the beam actually lands on: the topmost WATER cell of an ocean/lake column,
//     or the open cell resting on rock for dry land. It absorbs what got through the air, times (1 - albedo).
//   * EXPOSED BEDROCK — a SOLID cell whose slot 5 is space. Bare rock facing the sky radiates; nothing else in
//     this kernel would ever let it.
// A cell with ROCK ABOVE IT holds none of them. That is the fix for the largest of the four errors: `up` being
// solid used to make a cell "top of atmosphere", so 1615 roofed pockets — 32% of the set, measured on this
// build at seed 4242 — had the sun shone on them and radiated to space THROUGH SOLID ROCK. 189 cave floors did
// the same as "ground". Rock is opaque in both directions, so the outward walk (`sky_clear`) settles it.
//
// PER-CELL SOLAR: insolation = max(0, dot(cell_radial, sun_dir)); cell_radial = the binding-14 outward unit
// vector for this cell, sun_dir = the sun_x/sun_y/sun_z push-constant (world-space unit vector to the sun,
// its MAGNITUDE carrying orbital distance + atmospheric transmission). That insolation feeds a real energy
// balance in main(), NOT a relax-to-target — see the ENERGY BALANCE block.
//
// ALTITUDE: there is no LAPSE term and there must not be one. High ground is cold here for the physical
// reason it is cold on Earth — a thinner air column overhead intercepts less of its outgoing longwave — which
// enters through EMISSIVITY reading the hydrostatic `pressure` channel, not through a subtracted constant.
// The paragraph that used to sit here described that deleted LAPSE and its PLANET_RELIEF tuning; it is gone
// so nobody restores it. `pos` (binding 3) survives for other uses.

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict buffer Temp { float temp[]; };
layout(set = 0, binding = 1, std430) restrict readonly buffer Solid { float solid[]; };
layout(set = 0, binding = 3, std430) restrict readonly buffer Pos { float pos[]; };          // per-cell world position, packed flat c*3+{0,1,2}
layout(set = 0, binding = 4, std430) restrict readonly buffer Snow { float snow[]; };        // frozen H2O -> ice albedo
layout(set = 0, binding = 5, std430) restrict readonly buffer Water { float water[]; };      // liquid -> ocean albedo + heat capacity
layout(set = 0, binding = 6, std430) restrict readonly buffer RockFill { float rock_fill[]; }; // bedrock fraction -> heat capacity
layout(set = 0, binding = 7, std430) restrict readonly buffer Pressure { float pressure[]; }; // weight of the air ABOVE this cell -> greenhouse strength
// PRE-SOLAR TEMPERATURE SNAPSHOT — LASphereThermalPass's conduction scratch, which still holds exactly what
// `temp` held when this kernel was dispatched (conduct gathers into it, copy pushes it back to temp, nothing
// touches it after). The two-layer longwave exchange below needs the PARTNER cell's temperature, and `temp`
// is written IN PLACE by this same dispatch, so reading it would be a race whose outcome depends on
// scheduling — the same seed would stop reproducing. This is the stable read.
layout(set = 0, binding = 8, std430) restrict readonly buffer TempPrev { float temp_prev[]; };
layout(set = 0, binding = 14, std430) restrict readonly buffer Radial { float radial[]; };  // per-cell outward unit vec, packed flat c*3+{0,1,2}
layout(set = 0, binding = 15, std430) restrict readonly buffer Neigh { int nbr[]; };         // idx*6 + slot
// LIVING PLANT MATTER -> canopy cover -> surface albedo (see the VEGETATION block below). Bound at 27 rather
// than at BIOMASS's slot number 11, because bindings up to 26 shadow the reaction engine's slot enum and a
// binding that half-matches it is worse than one that plainly does not.
layout(set = 0, binding = 27, std430) restrict readonly buffer Biomass { float biomass[]; };
// CARRIERS THIS KERNEL DOES NOT USE ITSELF, bound because rc_shared.glsli needs every one of them.
// Leaving one out is exactly the divergence that file exists to end.
layout(set = 0, binding = 20, std430) restrict readonly buffer Lava { float lava[]; };
layout(set = 0, binding = 21, std430) restrict readonly buffer Fuel { float fuel[]; };
layout(set = 0, binding = 23, std430) restrict readonly buffer Detritus { float detritus[]; };

layout(push_constant, std430) uniform Params {
	uint cell_count;
	// REAL seconds one field step represents (LAMaterialFieldSphereStep3D.real_seconds_per_step, 43.2 at the
	// shipped 200 s day). It is PUSHED, not hardcoded, because it is a property of this world's time
	// compression rather than of matter — and because this kernel used to carry its own copy of a DIFFERENT
	// clock: `const float STEP_DT = 0.1`, the SIMULATED step, while heat_sphere3d.glsl in the same pass ran on
	// the real one. See the CAPACITY block below for what that cost and how it was reconciled.
	float dt_s;
	// Grid cell edge in METRES (LASphereGrid.cell_size, 16.0 on the shipped 500-radius planet). It is what
	// turns a volumetric heat capacity into the AREAL one this kernel divides by, so the solar balance and the
	// conduction kernel dispatched beside it finally describe the same lump of matter. Pushed, not hardcoded:
	// it is a property of this grid, and it must re-derive at another resolution.
	float cell_size;
	uint pad2;
	float sun_x;        // world-space unit vector pointing TOWARD the sun (magnitude carries insolation)
	float sun_y;
	float sun_z;
	float sea_radius;   // world radius of the sea shell — altitude datum for the lapse term
} params;

// Constants — the authoritative surface-temperature model (no GDScript mirror; the old MaterialHeat3D.gd is gone).
//
// EVERYTHING THAT USED TO PRESCRIBE A TEMPERATURE HAS BEEN DELETED, and with it a page of constants that
// described the prescribed model: AMBIENT_NIGHT (a night-side floor), SOLAR_WARMTH (a sub-solar bonus),
// AMBIENT_RELAX and ATMOS_RELAX (the rates those targets were imposed at), ATMOS_BAND_BELOW/ABOVE (the shell
// the anchor covered), and LAPSE. They are gone rather than merely unused, because a constant that still
// reads as live is worse than no constant: `target = AMBIENT_NIGHT + SOLAR_WARMTH * insolation` survived as
// dead code for three commits after the branch that used it was removed, computed every step by every cell
// and read by nothing, with a comment block above it still explaining how it set the climate.
//
// THE ALTITUDE TERM IS BACK, AND NOTHING PRESCRIBES IT. For three commits after LAPSE was deleted there was
// no height dependence anywhere in the surface temperature: a mountain top and a sea-level cell at the same
// latitude, albedo and heat capacity reached the SAME equilibrium, so snow-capped peaks and the alpine
// treeline were produced by nothing at all and snow_cells / sea_ice_cells sat at zero.
//
// The fix was never to re-prescribe a lapse. A real surface is colder at height because the air column above
// it is thinner — less mass, so less of its outgoing longwave is intercepted and returned. That is the
// GREENHOUSE, and a greenhouse is exactly what EMISSIVITY stands for, so the height dependence belongs in
// EMISSIVITY rather than in a subtracted constant. The hydrostatic `pressure` channel is the overlying air
// mass, measured (wind_pressure_sphere3d WALK 5 integrates the weight of the air above every cell), and
// binding it here is the whole change. See the GREENHOUSE block below for the model and its calibration.
//
// A cell that stands high sits under less air, is closer to radiating as a bare blackbody, and equilibrates
// colder — with no altitude appearing anywhere in the expression. Latitude, season, albedo, ocean lag and
// now altitude all fall out of the same one energy balance.
// ===== ENERGY BALANCE CONSTANTS ===================================================================
// MEASURED VALUES, NOT FITTED ONES. SOLAR_CONSTANT was 600.0, with a comment saying it was "sized so the
// sub-solar point equilibrates near 300 K" — i.e. the sun's brightness was chosen to make the output look
// right, which makes surface temperature an INPUT to this model rather than a prediction of it. It is now
// the measured 1361 W/m^2 at 1 AU, and STEFAN is the full Stefan-Boltzmann constant rather than a truncation.
//
// With real numbers the equilibrium is a RESULT: mean absorbed = S/4 * (1 - albedo) against sigma*eps*T^4
// gives ~288 K for an Earth-albedo planet with nothing tuned. If this world lands somewhere else, that is a
// finding about its albedo, its greenhouse or its interior — not a licence to re-dim the sun.
//
const float STEFAN = 5.670374419e-8;   // LAPhysical.STEFAN_BOLTZMANN — the measured constant, in full
const float SOLAR_CONSTANT = 1361.0;   // LAPhysical.SOLAR_CONSTANT_W_M2 — measured irradiance at 1 AU
const float KELVIN = 273.15;
// STABILITY LIMIT, and it is NOT a spare guard — it BINDS. Measured on this build: 399 surface cells hit it
// in a single step, worst |dT| 29.8 C/step against a limit of 5.0. Its old comment said "numerical guard
// only, never reached at equilibrium", which was false and hid the fact that real energy was being discarded
// every step at exactly the cells that matter most (lava, hot springs, the day/night terminator).
//
// A clamp that silently drops the excess is a lie in an energy balance: the cell reports a temperature the
// budget did not pay for. The fix is not a bigger number — dT scales as 1/heat_capacity, so a cell of bare
// air (the smallest rho*c there is) under a large flux genuinely wants a big step, and raising the limit just
// moves the threshold. It is SUB-STEPPING: split the update into N slices when the implied change is large, so the
// same total energy is applied but T^4 is re-evaluated as the cell warms, which is what makes it converge.
// The clamp remains underneath as a true last resort, and now reports rather than hides (dt_clamped).
const float MAX_DT_PER_STEP = 5.0;     // last-resort stability limit (see SUB-STEPPING below)
const int   MAX_SUBSTEPS = 8;          // slices per step when |dT| is large; 8 covers the measured 29.8 C
const float ALBEDO_GROUND = 0.15;
const float ALBEDO_WATER = 0.06;
const float ALBEDO_ICE = 0.65;
const float ICE_ALBEDO_GAIN = 40.0;    // snow mass -> reflectivity; a thin dusting already whitens a cell
// ===== VEGETATION — THE BIOLOGICAL HALF OF THE ICE-ALBEDO FEEDBACK ================================
// *(Added 2026-08-09. Until now `biomass` appeared nowhere in this kernel: a planet that greened absorbed
//  exactly as much sunlight as the bare ground it greened over, so the loop that makes a forest warm its own
//  climate — and a dying forest cool it — did not exist in either direction.)*
//
// A canopy is DARKER than the ground it grows on (0.08-0.15 conifer, 0.15-0.20 grass and crops, against
// 0.15 for this planet's bare ground), so the cell reflects at the canopy's albedo over the fraction of its
// ground the canopy COVERS and at the ground's albedo over the rest. That is an area-weighted mean, which is
// the same `mix` the wet and icy terms already are.
//
// THE COVER FRACTION IS NOT A RAMP WITH A CLAMP. It is Beer-Lambert extinction through the leaf area the
// cell carries — `1 - exp(-k * LAI)` — which saturates on its own, so unlike ICE_ALBEDO_GAIN below it needs
// no clamp and has no chosen saturation point. Closure is a measurement: at the observed LAI 3-4 of a closed
// canopy the interception is 0.78-0.86.
//
// AND LAI COMES FROM THE MASS THE CHANNEL ALREADY HOLDS, in three steps that each use a measured number:
//   areal dry mass  = biomass * RHO_CELLULOSE * cell_size   (biomass is a VOLUME FRACTION of the cell, like
//                                                            water/snow/rock_fill — LAReactionBalance
//                                                            .mol_per_unit: "a channel unit is the
//                                                            substance's own density, a full cell of it")
//   leaf mass       = areal dry mass * FOLIAGE_FRACTION      (a plant is mostly stem and root)
//   LAI             = leaf mass / LEAF_MASS_PER_AREA
// Measured on this planet at seed 4242: mean ground-cell biomass 0.00102, so 8.2 kg/m^2 of standing matter,
// 0.245 kg/m^2 of that foliage, LAI 3.1 — a just-closed canopy, which is the regime a vegetated cell should
// be in. Dropping FOLIAGE_FRACTION would make it LAI 102 and every vegetated cell would saturate at once.
const float RHO_CELLULOSE = 500.0;        // LAPhysical.DRY_WOOD_DENSITY_KG_M3 — LASubstances cellulose.density
const float ALBEDO_VEG = 0.12;            // LAPhysical.ALBEDO_VEGETATION — LASubstances cellulose.albedo
const float FOLIAGE_FRACTION = 0.03;      // LAPhysical.FOLIAGE_FRACTION_OF_PLANT_MASS
const float LEAF_MASS_PER_AREA = 0.080;   // LAPhysical.LEAF_MASS_PER_AREA_KG_M2
const float CANOPY_EXTINCTION = 0.5;      // LAPhysical.CANOPY_EXTINCTION_COEFF
// ===== HEAT CAPACITY — DERIVED FROM WHAT THE CELL IS MADE OF ======================================
// *(Rewritten 2026-08-03. This block used to declare four AREAL capacities as literals —
//  CAP_AIR 345600 / CAP_ROCK 604800 / CAP_WATER 3888000 / CAP_SNOW 1080000 — and its own comment worked out
//  that CAP_WATER implied 0.932 m of ocean against a real mixed layer of 20-100 m and admitted it was "wrong
//  by one to two orders of magnitude", then left it. Their whole provenance was the older unitless set
//  800/1400/9000/2500 multiplied by 432 to absorb a clock change. Nothing about them was ever measured.)*
//
// A cell's areal heat capacity is not a constant of anything. It is the volumetric heat capacity of the
// matter the cell HOLDS times the cell's own depth, and both of those are already known here: LAPhysical
// carries the rho*c of rock, air, water and snow, and `cell_size` is pushed. So it is derived per cell from
// the SAME volume-fraction mix heat_sphere3d.glsl and heat3d_buoyancy_sphere3d.glsl use — one expression,
// three kernels, no fourth number to drift.
//
// WHAT THE OLD LITERALS WERE ACTUALLY SAYING, against rho*c*dx for the very cell conduction was stepping:
//   WATER  3888000 vs 4.171e6 * 16 = 66736000   — 17.2x too small (0.93 m of ocean, not 16 m)
//   ROCK    604800 vs 2.436e6 * 16 = 38976000   — 64.4x too small (0.25 m of rock, not 16 m)
//   SNOW   1080000 vs 6.27e5  * 16 = 10032000   —  9.3x too small
//   AIR     345600 vs 1186    * 16 =    18976   — 18.2x too LARGE (291 m of air inside a 16 m cell)
// Two kernels in one pass disagreed by up to 64x about how much heat the same cell holds.
//
// THE OCEAN MIXED LAYER, SAID PLAINLY. One water cell is 16 m deep, so it now carries 16 m of water's
// thermal inertia — 6.67e7 J/m^2/K. A real wind-stirred mixed layer is 20-100 m, so this grid is at the
// shallow end of the real range and the sea will still swing a little faster than Earth's does. The honest
// fix for that is MORE CELLS in the mixed layer, not a bigger literal here: the number below is what the
// simulation actually contains, and inflating it would be re-inventing the constant this block deleted.
// A cell holding half water and half air is half of each, not the sum of two full cells — `solid`, `water`,
// `rock_fill` and `snow` are all FRACTIONS OF THE CELL VOLUME (SolidDerivePass: solid iff rock_fill >= 0.5),
// so the mix is by volume and air fills whatever is left. Identical text in heat_sphere3d.glsl (rc_of) and
// heat3d_buoyancy_sphere3d.glsl; change one and change all three.
// A CELL'S VOLUMETRIC HEAT CAPACITY — ONE definition for every kernel that books heat, because five
// copies in four different formulas is how heat gets created and destroyed at every exchange.
// Textual include: it binds all fifteen carriers by NAME, so it must sit
// below the buffer declarations. See rc_shared.glsli for the table of what each old copy left out.
// THE EIGHT CARRIERS rc_shared.glsli GAINED 2026-08-09. This kernel reads none of them itself; they are
// bound because a cell's heat capacity is a property of EVERYTHING in it, and these eight were counted
// nowhere, so every gram that crossed into one deleted its own thermal mass. Indices 30-37 are the same
// in all four heat kernels on purpose. Do not drop one because "this kernel does not need it".
layout(set = 0, binding = 30, std430) restrict readonly buffer Sediment { float sediment[]; };
layout(set = 0, binding = 31, std430) restrict readonly buffer Susp { float susp[]; };
layout(set = 0, binding = 32, std430) restrict readonly buffer Dust { float dust[]; };
layout(set = 0, binding = 33, std430) restrict readonly buffer Carbonate { float carbonate[]; };
layout(set = 0, binding = 34, std430) restrict readonly buffer Silica { float silica[]; };
layout(set = 0, binding = 35, std430) restrict readonly buffer Soil { float soil[]; };
layout(set = 0, binding = 36, std430) restrict readonly buffer Moisture { float moisture[]; };
layout(set = 0, binding = 37, std430) restrict readonly buffer Fungus { float fungus[]; };
#include "rc_shared.glsli"
// ===== GREENHOUSE — emissivity from the overlying air mass ========================================
// A grey atmosphere of optical depth tau lets a fraction 1/(1 + 0.75*tau) of the surface's blackbody flux
// reach space (the standard two-stream result, T_s^4 = T_e^4 * (1 + 0.75*tau)). So the greybody EMISSIVITY
// this kernel used to hardcode IS that fraction, and it is a function of how much air is overhead — which
// the `pressure` channel measures directly.
//
// TAU_SEA is DERIVED, not fitted: Earth's surface sits at 288 K against an effective radiating temperature
// of 255 K, so (288/255)^4 = 1.626 = 1 + 0.75*tau -> tau = 0.835 for a sea-level column. P_REF is this
// world's sea-level pressure, which wind_pressure_sphere3d states outright — G_ACC 33.5 against a column
// mass of ~2.99 puts it "at ~100, which is where the old P0 sat".
//
// THE FRACTION IS USED AS AN ABSORPTIVITY IN BOTH DIRECTIONS NOW, not as a multiplier on one cell's
// emission. *(Corrected 2026-08-03. This block used to end with two consequences stated as though each cell
// carried its own greybody emissivity: "a summit ... its emissivity rises and it equilibrates colder", and
// "TOP OF ATMOSPHERE ... emissivity approaches 1 and they radiate as bare blackbodies". The second is what
// made every column radiate to space twice — see the LONGWAVE block in main().)*
//   eps_a = 1 - 1/(1 + 0.75*tau*p/P_REF) is how much of the surface's infrared the air column INTERCEPTS,
//   and the air re-emits it, half up and half down. The surface radiates as the blackbody it is and gets the
//   downward half back.
//
// TWO CONSEQUENCES WORTH NAMING, because neither is coded for anywhere:
//   * ALTITUDE. exp(-relief/H_REF) with relief ~16 and H_REF ~50 leaves a summit under ~73% of the sea-level
//     column, so it gets less back-radiation and equilibrates colder. The lapse rate is an OUTPUT now.
//   * TOP OF ATMOSPHERE. The air layer's own temperature is set by what it intercepts from below against
//     what it radiates from both faces, so it settles well under the surface — which is what the top of an
//     atmosphere does. The vertical temperature structure comes from the same expression as the horizontal
//     one, and one column's outgoing longwave is (1 - eps_a)*sigma*Ts^4 + eps_a*sigma*Ta^4 exactly once.
//
// This also replaces 0.9, which was a round number chosen for a greybody and then paired with SOLAR_CONSTANT
// 600 "sized so the sub-solar point equilibrates near 300 K". At sea level the model below gives 0.615, so
// the pair is no longer consistent and the planet will run warmer until that is re-derived. Measure before
// touching SOLAR_CONSTANT: the last time it was cut 20% the global mean moved ONE degree, because the sun is
// not what sets this planet's temperature.
const float P_REF = 100.0;           // sea-level column pressure in this world's units
const float TAU_SEA = 0.835;         // LAPhysical.ATMOS_OPTICAL_DEPTH — LONGWAVE depth of a sea-level column
const float TAU_TWO_STREAM = 0.75;   // LAPhysical.TWO_STREAM_COEFF — the coefficient in T_s^4 = T_e^4 (1 + 0.75 tau)
// ===== COLUMN SHORTWAVE BUDGET — THE BEAM IS SPENT ONCE ===========================================
// *(Added 2026-08-03, and it is the largest energy-from-nothing term this simulation has had.)*
//
// WHAT WAS HAPPENING. `surface` was true for BOTH the top-of-atmosphere cell and the ground cell beneath it,
// and both then computed `absorbed = SOLAR_CONSTANT * (1 - albedo) * insolation` from the SAME undiminished
// insolation. The top cell did not shade the ground; neither shaded the seabed. So every lit column absorbed
// the solar constant TWICE, and the gauge summed the two halves into one `absorbed_total`. Measured on this
// build, seed 4242, 600 frames: energy_abs_toa 1.46e6 against energy_abs_ground 1.03e6, so 59% of the
// planet's reported shortwave input was the duplicate.
//
// WHAT REPLACES IT. Beer-Lambert down the column, with the air's own mass as the optical path:
//     trans   = exp(-TAU_SW * (p_surface / P_REF) / mu)      fraction of the beam that reaches the ground
//     TOA     absorbs  S * mu * (1 - trans)                  the air column's share
//     surface absorbs  S * mu *  trans * (1 - albedo)        what the ground or sea keeps
//     (the rest, S * mu * trans * albedo, is reflected back to space and absorbed by nobody)
// The three add to exactly S * mu, so a column can no longer absorb more than arrives. `p_surface` is the SAME
// NUMBER on both sides — the TOA cell walks down its own column to the very cell the beam lands on and reads
// that cell's overlying air mass — so the partition cannot drift apart at a mountain or a coast.
//
// TAU_SW IS NOT TAU_SEA, AND THAT IS THE WHOLE GREENHOUSE. It is tempting to reuse the 0.835 above, and it
// would be a physical error: an atmosphere equally opaque to sunlight and to thermal infrared has no
// greenhouse effect at all. Air is nearly transparent in the visible and nearly opaque in the infrared, so
// the two optical depths are separate measured quantities. TAU_SW comes from Earth's own budget — 78 of
// 341 W/m^2 absorbed in the atmosphere, tau = -ln(1 - 0.2287).
const float TAU_SW = 0.2597;         // LAPhysical.ATMOS_SW_OPTICAL_DEPTH — SHORTWAVE depth of a sea-level column
// The slant path is 1/cos(zenith), which diverges at the terminator. The real relative air mass saturates
// near 38 there because the atmosphere is a curved shell rather than a slab, so THAT is what bounds it — a
// measured limit, not an epsilon chosen to stop a division.
const float AIR_MASS_HORIZON = 38.0; // LAPhysical.AIR_MASS_HORIZON
// Water fraction at which a cell counts as the sea/lake SURFACE rather than as air holding some spray. Matches
// atmos_evap_sphere3d.glsl's own `water[above] < MAX_MASS * 0.5` interface test, so the cell this kernel
// lights is the same cell that one evaporates from.
const float WATER_SURFACE_MIN = 0.5;
// Hard bound on a radial column walk. The shell is `depth` cells (20 on the shipped grid); 64 is a loop
// guard, not a physical quantity, and a walk that hits it has found a malformed neighbour table.
const int MAX_COLUMN_WALK = 64;

// Walk outward to the top of this cell's column. Returns the index of the outermost open cell — the
// top-of-atmosphere cell this one exchanges longwave with — or -1 if ROCK blocks the way, which is what
// makes a cave, a lava tube or the space under an overhang trade no radiation with the sky in either
// direction. `start` is returned when it is itself the top.
int find_column_top(uint start) {
	int c = int(start);
	for (int s = 0; s < MAX_COLUMN_WALK; ++s) {
		int u = nbr[uint(c) * 6u + 5u];
		if (u < 0) {
			return c;                                      // reached space: c is the top
		}
		if (solid[u] != 0.0) {
			return -1;                                     // rock overhead
		}
		c = u;
	}
	return -1;
}

// Walk inward from the top of the column to the cell the beam lands on, applying the SAME test `main()` uses
// to decide a MATERIAL SURFACE: the first cell holding water is a sea/lake surface; otherwise the first cell
// resting on rock is the ground. Returns -1 for a column that is open all the way down (no floor in the
// shell), which absorbs only its atmospheric share. One walk per top-of-atmosphere cell, so O(cells) overall.
int find_column_surface(uint start) {
	int c = int(start);
	for (int s = 0; s < MAX_COLUMN_WALK; ++s) {
		if (solid[c] != 0.0) {
			return -1;
		}
		if (water[c] >= WATER_SURFACE_MIN) {
			return c;                                      // topmost water cell: the sea/lake surface
		}
		int d = nbr[uint(c) * 6u + 0u];
		if (d < 0) {
			return -1;                                     // open to the bottom of the shell
		}
		if (solid[d] != 0.0) {
			return c;                                      // c rests on rock: the ground
		}
		c = d;
	}
	return -1;
}

void main() {
	uint idx = gl_GlobalInvocationID.x;
	if (idx >= params.cell_count) {
		return;
	}
	int up = nbr[idx * 6u + 5u];
	int down = nbr[idx * 6u + 0u];
	bool solid_here = solid[idx] != 0.0;
	bool faces_space = up < 0;

	// TOP OF ATMOSPHERE: the outermost OPEN cell of the column. It stands for the whole air column in the
	// radiative exchange — it intercepts the share of the surface's infrared the air absorbs and re-radiates
	// it from both faces. `(up < 0)` and nothing else: a cell with rock over it is
	// roofed, not exposed. *(Corrected 2026-08-03; the old test also accepted `solid[up] != 0`, which put 1615
	// underground pockets in this set and shone the sun on them.)*
	bool toa = faces_space && !solid_here;
	// EXPOSED BEDROCK: solid rock whose slot 5 is space. Bare rock absorbs sunlight and radiates to the sky —
	// the old `if (solid) return` gave the crust a conductive sink only, so any column capped by rock traded no
	// radiation at all. It is the same energy balance; the cell is simply made of rock.
	bool bedrock_top = faces_space && solid_here;
	// MATERIAL SURFACE: the cell the beam lands on. The topmost WATER cell for a sea or lake, the open cell
	// resting on rock for dry land — and neither if something opaque is overhead.
	//
	// THE SEA SURFACE USED TO BE EXCLUDED ENTIRELY. With the old pair of tests, a water cell with air above and
	// more water below was neither top-of-atmosphere nor ground-hugging, so for any ocean column two or more
	// cells deep the cell that absorbed the sunlight and radiated to space was THE ONE LYING ON THE SEABED,
	// with nothing attenuating the beam on the way down. The sea surface — where an ocean actually exchanges
	// energy with the sky — did neither. `submerged` is what retires the seabed from the job.
	bool submerged = (up >= 0) && (solid[up] == 0.0) && (water[up] >= WATER_SURFACE_MIN);
	bool mat_surface = false;
	int top_c = -1;
	if (!solid_here && !submerged) {
		bool on_rock = (down >= 0) && (solid[down] != 0.0);
		bool water_top = clamp(water[idx], 0.0, 1.0) >= WATER_SURFACE_MIN;
		if (on_rock || water_top) {
			top_c = find_column_top(idx);                  // -1 when roofed by rock
			mat_surface = top_c >= 0;
		}
	}
	bool surface = toa || bedrock_top || mat_surface;

	// Per-cell insolation from this cell's outward radial vs the sun direction (the terminator).
	uint rb = idx * 3u;
	vec3 cell_radial = vec3(radial[rb + 0u], radial[rb + 1u], radial[rb + 2u]);
	vec3 sun_dir = vec3(params.sun_x, params.sun_y, params.sun_z);
	float insolation = max(0.0, dot(cell_radial, sun_dir));

	// NOTE: altitude is deliberately not read here any more. It fed the LAPSE term, which was part of the
	// prescribed model and went with it; see the constants block for why re-prescribing it is the wrong fix
	// and what has to exist first. `params.sea_radius` is still the altitude datum for other passes.

	if (surface) {
		// ===== REAL ENERGY BALANCE =====================================================================
		// dT = (absorbed shortwave - emitted longwave) * dt / heat capacity.
		//
		// This replaced `temp += AMBIENT_RELAX * (target - temp)`, a spring pulling every cell to an
		// algebraic answer. A relax-to-target cannot cool below its target however much energy you remove,
		// nor warm above it however much you add — which is why this planet needed FOUR separate band-aids
		// to stay stable: water's freezing point moved to 12.5 C because 0 C "can never fire here", a
		// hot-spring gate to stop the ocean thermostat quenching geothermal springs, arc volcanoes kept
		// artificially rare "so sustained volcanic heat doesn't accumulate and bake the planet", and a cap
		// on cloud opacity to stop a snowball runaway. All four are consequences of having no sink.
		//
		// ALBEDO closes the ice-albedo feedback, which is the loop the cloud cap was faking. Snow and ice
		// reflect; open water absorbs nearly everything; bare ground sits between. Nothing computed albedo
		// anywhere in this simulation before now.
		float wet = clamp(water[idx], 0.0, 1.0);
		float icy = clamp(snow[idx] * ICE_ALBEDO_GAIN, 0.0, 1.0);
		// CANOPY COVER, from the leaf area this cell's standing biomass carries. See the VEGETATION block.
		// exp() of a large negative underflows to 0, which IS a closed canopy — no clamp is needed and none is
		// written, because inventing one would put a chosen saturation point back in.
		float leaf_kg_m2 = max(biomass[idx], 0.0) * RHO_CELLULOSE * params.cell_size * FOLIAGE_FRACTION;
		float lai = leaf_kg_m2 / LEAF_MASS_PER_AREA;
		float veg = 1.0 - exp(-CANOPY_EXTINCTION * lai);
		// THE NESTING IS THE PHYSICS, and it is why vegetation goes INSIDE the water mix rather than beside it.
		// Plants darken the LAND; a cell that is open sea reflects as water however much biomass drifts in it,
		// and mixing a 0.12 canopy over a 0.06 sea would make plankton BRIGHTEN the ocean, which is backwards.
		// Snow then covers whatever is underneath, canopy included.
		//
		// WHAT THAT LAST STEP OVERSTATES, said plainly: real conifers stand PROUD of a snowpack and mask it, so
		// a snowy boreal forest sits near 0.2-0.3 where snowy open ground reaches 0.65-0.8. Reproducing that
		// needs a canopy HEIGHT against a snow depth and this substrate stores neither, so snow here whitens a
		// forest as completely as it whitens a field. That is an overstatement of the SNOW term, named, not a
		// term missing from the vegetation one.
		float land = mix(ALBEDO_GROUND, ALBEDO_VEG, veg);
		float albedo = mix(mix(land, ALBEDO_WATER, wet), ALBEDO_ICE, icy);

		// HEAT CAPACITY per cell: the volumetric heat capacity of what the cell holds, times the cell's own
		// depth. Derived, not declared — see the block above for the four literals this replaced and by how
		// much each was wrong.
		float cap = max(rc_of(idx) * params.cell_size, 1.0);

		// ===== THE COLUMN'S TWO CELLS, AND THE ONE AIR MASS BETWEEN THEM ===============================
		// `p_beam` is the overlying air mass at the cell the beam LANDS on. It sets BOTH how much sunlight
		// survives the trip down AND how much of the surface's infrared the air intercepts on the way back
		// up, so the top-of-atmosphere cell and the material surface must build their shares from the SAME
		// number — which they do, because each finds the other by walking its own column. On step 0 the
		// pressure channel is still all-zero (wind_pressure seeds it AFTER Thermal's first dispatch,
		// PASS_SCRIPTS order), so fall back to the sea-level reference for that one step.
		float p_col = pressure[idx];
		if (p_col <= 0.0) {
			p_col = P_REF;
		}
		int surf_c = -1;
		float p_beam = 0.0;                 // exposed bedrock faces space with no air above it at all
		if (mat_surface) {
			surf_c = int(idx);
			p_beam = p_col;
		} else if (toa) {
			surf_c = find_column_surface(idx);
			p_beam = (surf_c >= 0) ? pressure[surf_c] : p_col;
			if (p_beam <= 0.0) {
				p_beam = P_REF;
			}
		}
		// SHORTWAVE — see the COLUMN SHORTWAVE BUDGET block for why the beam is split this way and why
		// TAU_SW is not TAU_SEA. Slant path bounded by the real horizon air mass rather than by an epsilon.
		float mu = max(insolation, 1.0 / AIR_MASS_HORIZON);
		float trans = exp(-TAU_SW * (p_beam / P_REF) / mu);
		float absorbed = 0.0;
		if (toa) {
			absorbed += SOLAR_CONSTANT * insolation * (1.0 - trans);            // the air column's share
		}
		if (mat_surface || bedrock_top) {
			absorbed += SOLAR_CONSTANT * insolation * trans * (1.0 - albedo);   // what the surface keeps
		}

		// ===== LONGWAVE — THE COLUMN SHEDS ITS HEAT ONCE ===============================================
		// *(Rewritten 2026-08-03, and it is the mirror image of the shortwave defect: the SAME two cells were
		//  doing it to the outgoing side.)*
		//
		// Each cell used to compute `emitted = STEFAN * emissivity * T^4` from its OWN pressure and lose that
		// to space independently. But `emissivity = 1/(1 + 0.75 tau)` is not a property of the ground: it is
		// the fraction of the SURFACE's blackbody flux that survives the whole air column, so it already
		// contains the atmosphere's own emission. Adding the top-of-atmosphere cell's near-blackbody
		// sigma*T^4 on top made every column shed its heat twice. Measured on the pre-fix build, seed 4242,
		// 600 frames: energy_emit_toa 2.17e6 against energy_emit_ground 1.03e6, so 68% of the planet's
		// reported outgoing longwave was the duplicate. It very nearly cancelled the duplicated SHORTWAVE
		// (2.49e6 absorbed against 3.20e6 emitted, imbalance -0.287), which is why the books LOOKED nearly
		// closed while both sides were wrong — and why fixing only one of them sends the planet cold.
		//
		// What replaces it is the standard two-layer grey exchange, with the air's ABSORPTIVITY
		// eps_a = 1 - eps used in BOTH directions, which is what makes a greenhouse a greenhouse:
		//     surface      emits sigma*Ts^4 up,       absorbs eps_a*sigma*Ta^4  <- BACK-RADIATION, new here
		//     atmosphere   emits eps_a*sigma*Ta^4 UP AND DOWN, absorbs eps_a*sigma*Ts^4
		//     to space     (1 - eps_a)*sigma*Ts^4 + eps_a*sigma*Ta^4            — once, and only once
		// The greenhouse stops being a multiplier that quietly shrinks the ground's emissivity and becomes the
		// downward flux it physically is. ALTITUDE still enters exactly where it did and still as physics: a
		// summit sits under less air, so its eps_a is smaller, so it gets less back-radiation and equilibrates
		// colder. Nothing prescribes a lapse.
		//
		// The PARTNER's temperature comes from the pre-solar SNAPSHOT (binding 8), never from `temp`, which
		// this dispatch is writing in place — reading that would make the result depend on scheduling and the
		// same seed would stop reproducing. Within a step the exchange is therefore explicit: each cell
		// evolves its own T^4 across the sub-step slices while the partner's term is held at the snapshot.
		// That is the ordinary O(dt) coupling error of an explicit scheme, bounded by MAX_DT_PER_STEP; no
		// term is dropped or applied twice, so it is an accuracy limit and not a leak.
		float eps_a = 1.0 - 1.0 / (1.0 + TAU_TWO_STREAM * TAU_SEA * (p_beam / P_REF));
		float lw_in = 0.0;                                     // longwave RECEIVED, constant across slices
		if (toa && surf_c >= 0) {
			float ts = max(temp_prev[surf_c] + KELVIN, 1.0);
			lw_in += eps_a * STEFAN * ts * ts * ts * ts;        // the surface flux the air intercepts
		}
		if (mat_surface && top_c >= 0) {
			float ta = max(temp_prev[top_c] + KELVIN, 1.0);
			lw_in += eps_a * STEFAN * ta * ta * ta * ta;        // the air's downward half — the greenhouse
		}
		// How many blackbody faces this cell radiates from: the air layer emits eps_a upward AND downward, a
		// material surface or bare rock emits as a full blackbody upward.
		float lw_self = 0.0;
		if (toa) {
			lw_self += 2.0 * eps_a;
		}
		if (mat_surface || bedrock_top) {
			lw_self += 1.0;
		}

		float t_k = max(temp[idx] + KELVIN, 1.0);              // clamp keeps T^4 finite if a cell goes wild
		float emitted = lw_self * STEFAN * t_k * t_k * t_k * t_k - lw_in;
		float dT = (absorbed - emitted) * params.dt_s / cap;
		// Numerical guard ONLY (not a physics clamp): one step may not move a cell more than this, so a
		// transient cannot NaN the field. Equilibrium is unaffected — it is reached over many steps.
		// SUB-STEP rather than truncate. One Euler step of a T^4 sink is only valid while T barely moves;
		// when it does not, slice the interval and re-evaluate the emission each slice. The equilibrium is
		// unchanged, and the cells that used to lose 25 C/step of real cooling now actually cool.
		int slices = int(clamp(ceil(abs(dT) / MAX_DT_PER_STEP), 1.0, float(MAX_SUBSTEPS)));
		float sub_dt = params.dt_s / float(slices);
		float t_c = temp[idx];
		for (int s = 0; s < slices; ++s) {
			float tk = max(t_c + KELVIN, 1.0);
			float em = lw_self * STEFAN * tk * tk * tk * tk - lw_in;
			// Still clamp each SLICE, so a pathological cell cannot run away — but with 8 slices this is a
			// genuine last resort rather than the every-step truncation it had become.
			t_c += clamp((absorbed - em) * sub_dt / cap, -MAX_DT_PER_STEP, MAX_DT_PER_STEP);
		}
		temp[idx] = t_c;
	}
	// INTERIOR AIR IS LEFT TO CONDUCTION AND BUOYANCY, which is what an atmosphere actually is.
	//
	// There used to be a second branch here pulling every cell in the habitable band toward the same
	// algebraic target at ATMOS_RELAX = 0.14, a rate chosen expressly to OUTVOTE lateral conduction. Its own
	// comment gave the reason: conduction was homogenizing the equator-to-pole gradient, so the gradient was
	// re-asserted by fiat every step. That is not a radiative anchor, it is the answer being fed back in, and
	// while it stood no change to the real physics could move the climate — measured, cutting the solar
	// constant 20% moved the global mean by ONE degree.
	//
	// With a genuine sink at the surface the gradient no longer needs defending: the equator absorbs more
	// than it emits and the poles emit more than they absorb, continuously, so conduction spreading heat
	// poleward is the transport doing its job rather than an error to suppress. If the gradient still
	// flattens, that is a real finding about circulation strength and belongs in the wind solver — not here,
	// and not fixed by pinning air to a formula.
}
