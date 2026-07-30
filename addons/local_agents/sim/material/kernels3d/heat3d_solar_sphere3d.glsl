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
// SURFACE / SKY cell on the sphere: there are no columns. A cell is a SKY-EXPOSED surface cell iff it is OPEN
// (solid == 0) and its OUTWARD-radial neighbour (nbr slot 5) is -1 (space boundary) or solid — i.e. it is the
// OUTERMOST open cell reached walking slot 5 outward until you hit -1 or rock. That local test is exactly the
// landing set of the "walk slot 5 outward" the box did by scanning a column from the top down, and because each
// surface cell only touches ITSELF it is race-free. Non-surface cells are left as conduction produced them
// (mirrors the box touching only the top cell). Runs AFTER conduction, IN PLACE on the temp buffer.
//
// PER-CELL SOLAR: insolation = max(0, dot(cell_radial, sun_dir)); cell_radial = the binding-14 outward unit
// vector for this cell, sun_dir = the NEW sun_x/sun_y/sun_z push-constant (world-space unit vector to the sun).
// target = AMBIENT_NIGHT + SOLAR_WARMTH * insolation, then relax by AMBIENT_RELAX. The night side relaxes to the
// bare AMBIENT_NIGHT floor; the sub-solar point to AMBIENT_NIGHT + SOLAR_WARMTH.
//
// ALTITUDE LAPSE — RESTORED (climate lane). The box target subtracted a lapse * (world_height - sea_level) so
// high ground read cold (snow-capped peaks + an alpine treeline at ANY latitude). The box→sphere port dropped
// it claiming "no per-cell world-position buffer is available." That claim is stale: the driver already packs a
// per-cell world position (`pos`, flat float3 c*3+{0,1,2}, the SAME buffer heat3d_cool binds) and hands it to
// this pass via `bufs["pos"]`. We bind it here (binding 3) and compute the cell's ALTITUDE above the sea shell
// = max(0, length(pos) - sea_radius), then subtract LAPSE * altitude from the insolation target. On the sphere
// "up" is the outward radial, so altitude is a radial distance above the sea-surface RADIUS (sea_radius, the
// same push param heat3d_cool uses) — not a planar height. This is pure GEOMETRY: a peak is cold because it is
// FAR FROM THE CENTRE, independent of where the sun is, so snow caps the highest terrain on the equator too and
// the treeline descends toward the poles (where the insolation base is already low). No special-case "mountain"
// or "snow" code — the cold peak falls out of one lapse term over the shared position field.
// Constants originated in MaterialHeat3D.gd, which is deleted — see the note above the constant block, which
// already says so. LAPSE is tuned for the PLANET_RELIEF≈16 / sea_radius≈248 world scale.

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict buffer Temp { float temp[]; };
layout(set = 0, binding = 1, std430) restrict readonly buffer Solid { float solid[]; };
layout(set = 0, binding = 3, std430) restrict readonly buffer Pos { float pos[]; };          // per-cell world position, packed flat c*3+{0,1,2}
layout(set = 0, binding = 4, std430) restrict readonly buffer Snow { float snow[]; };        // frozen H2O -> ice albedo
layout(set = 0, binding = 5, std430) restrict readonly buffer Water { float water[]; };      // liquid -> ocean albedo + heat capacity
layout(set = 0, binding = 6, std430) restrict readonly buffer RockFill { float rock_fill[]; }; // bedrock fraction -> heat capacity
layout(set = 0, binding = 14, std430) restrict readonly buffer Radial { float radial[]; };  // per-cell outward unit vec, packed flat c*3+{0,1,2}
layout(set = 0, binding = 15, std430) restrict readonly buffer Neigh { int nbr[]; };         // idx*6 + slot

layout(push_constant, std430) uniform Params {
	uint cell_count;
	uint pad0;
	uint pad1;
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
// WHAT THIS COSTS, STATED RATHER THAN DISCOVERED LATER: there is now NO ALTITUDE TERM ANYWHERE in the
// surface temperature. LAPSE was the only thing making high ground cold, and the surface energy balance
// below has no height dependence at all — a mountain top and a sea-level cell at the same latitude, albedo
// and heat capacity reach the SAME equilibrium. So snow-capped peaks and the alpine treeline that the old
// comment credited to "geometry" are not currently produced by anything, and that is a likelier reason for
// snow_cells and sea_ice_cells sitting at zero than the global floor being a few degrees too warm.
//
// The fix is NOT to re-prescribe a lapse. On a real planet the surface is colder at height because the air
// column above it is thinner: less mass, less downwelling longwave, and adiabatic cooling of anything that
// rises. Two of those need a hydrostatic pressure channel, which this substrate does not carry yet, and the
// third needs the greybody EMISSIVITY below to vary with the overlying air mass instead of being a constant.
// That is the same missing pressure term the jet stream is waiting on, so one piece of work buys both.
// ===== ENERGY BALANCE CONSTANTS ===================================================================
// Target is EARTH-LIKE behaviour, so these are derived rather than fitted to this world's old numbers.
// STEFAN is the real Stefan-Boltzmann constant; EMISSIVITY is a greybody atmosphere (a value below 1 is
// what a greenhouse does — it holds the surface warmer than its bare radiative temperature).
// SOLAR_CONSTANT is in the same W/m^2-like units, sized so the sub-solar point equilibrates near 300 K:
//   absorbed = S*(1-a)*1  ==  emitted = sigma*eps*T^4   ->   S ~ 600 at a=0.15, eps=0.9, T=300 K.
// The heat capacities set how far a night cools before dawn. At 288 K a cell radiates ~390 W/m^2, so over
// a ~31 s night (half a 63 s rotation, 310 steps at 0.1 s) it sheds ~12000 J/m^2 — a capacity near 800
// gives a ~15 K diurnal swing on land. Water is an order up, which is what makes the ocean lag.
const float STEFAN = 5.670374e-8;
const float EMISSIVITY = 0.9;
const float SOLAR_CONSTANT = 600.0;
const float KELVIN = 273.15;
const float STEP_DT = 0.1;             // the field's fixed step (LAMaterialFieldSphereStep3D.STEP_DT)
const float MAX_DT_PER_STEP = 5.0;     // numerical guard only, never reached at equilibrium
const float ALBEDO_GROUND = 0.15;
const float ALBEDO_WATER = 0.06;
const float ALBEDO_ICE = 0.65;
const float ICE_ALBEDO_GAIN = 40.0;    // snow mass -> reflectivity; a thin dusting already whitens a cell
const float HEAT_CAP_AIR = 800.0;
const float HEAT_CAP_ROCK = 1400.0;
const float HEAT_CAP_WATER = 9000.0;   // the ocean's thermal inertia — why coasts are mild
const float HEAT_CAP_SNOW = 2500.0;

void main() {
	uint idx = gl_GlobalInvocationID.x;
	if (idx >= params.cell_count) {
		return;
	}
	if (solid[idx] != 0.0) {
		return;                                            // rock is not a sky cell
	}
	// TWO insolation surfaces on the shell:
	//   * TOP-OF-ATMOSPHERE — the outermost open cell (its OUTWARD neighbour, slot 5, is space or rock). This is
	//     the historical terminator surface: the sun bakes/freezes the exposed top of the air column and
	//     conduction/buoyancy carry it down. Radius ≈ shell top for EVERY column, so a lapse here would be a
	//     near-uniform giant offset that just freezes the whole atmosphere — so the lapse does NOT apply here.
	//   * GROUND-HUGGING — an air cell resting directly ON terrain (its INWARD neighbour, slot 0, is solid rock).
	//     This is the set snow deposits on (matches snowice_sphere3d), and its RADIUS TRACKS THE TERRAIN, so its
	//     altitude above the sea shell varies from ~0 in the valleys to the relief height on the peaks. The lapse
	//     applies HERE, cooling high ground below freezing → snow-capped peaks + an alpine treeline at ANY
	//     latitude, straight out of geometry. Lowland ground stays at the full insolation target (temperate).
	int up = nbr[idx * 6u + 5u];
	int down = nbr[idx * 6u + 0u];
	bool top_of_atm = (up < 0) || (solid[up] != 0.0);
	bool ground_hug = (down >= 0) && (solid[down] != 0.0);
	bool surface = top_of_atm || ground_hug;

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
		float albedo = mix(mix(ALBEDO_GROUND, ALBEDO_WATER, wet), ALBEDO_ICE, icy);

		// HEAT CAPACITY per cell, from channels that already exist — no new buffer. This is the thermal
		// inertia that lets a night side coast instead of radiating to absolute zero, and it is why an
		// ocean lags the land it sits beside.
		float cap = HEAT_CAP_AIR
			+ HEAT_CAP_ROCK  * clamp(rock_fill[idx], 0.0, 1.0)
			+ HEAT_CAP_WATER * wet
			+ HEAT_CAP_SNOW  * clamp(snow[idx], 0.0, 1.0);

		float t_k = max(temp[idx] + KELVIN, 1.0);              // clamp keeps T^4 finite if a cell goes wild
		float absorbed = SOLAR_CONSTANT * (1.0 - albedo) * insolation;
		float emitted  = STEFAN * EMISSIVITY * t_k * t_k * t_k * t_k;
		float dT = (absorbed - emitted) * STEP_DT / cap;
		// Numerical guard ONLY (not a physics clamp): one step may not move a cell more than this, so a
		// transient cannot NaN the field. Equilibrium is unaffected — it is reached over many steps.
		temp[idx] += clamp(dT, -MAX_DT_PER_STEP, MAX_DT_PER_STEP);
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
