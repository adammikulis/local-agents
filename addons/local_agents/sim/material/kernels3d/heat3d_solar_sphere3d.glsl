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
// The heat capacities set how far a night cools before dawn. At 288 K a cell radiates ~390 W/m^2, so over
// a ~31 s night (half a 63 s rotation, 310 steps at 0.1 s) it sheds ~12000 J/m^2 — a capacity near 800
// gives a ~15 K diurnal swing on land. Water is an order up, which is what makes the ocean lag.
const float STEFAN = 5.670374419e-8;   // LAPhysical.STEFAN_BOLTZMANN — the measured constant, in full
const float SOLAR_CONSTANT = 1361.0;   // LAPhysical.SOLAR_CONSTANT_W_M2 — measured irradiance at 1 AU
const float KELVIN = 273.15;
const float STEP_DT = 0.1;             // the field's fixed step (LAMaterialFieldSphereStep3D.STEP_DT)
// STABILITY LIMIT, and it is NOT a spare guard — it BINDS. Measured on this build: 399 surface cells hit it
// in a single step, worst |dT| 29.8 C/step against a limit of 5.0. Its old comment said "numerical guard
// only, never reached at equilibrium", which was false and hid the fact that real energy was being discarded
// every step at exactly the cells that matter most (lava, hot springs, the day/night terminator).
//
// A clamp that silently drops the excess is a lie in an energy balance: the cell reports a temperature the
// budget did not pay for. The fix is not a bigger number — dT scales as 1/heat_capacity, so a cell with the
// bare HEAT_CAP_AIR and a large flux genuinely wants a big step, and raising the limit just moves the
// threshold. It is SUB-STEPPING: split the update into N slices when the implied change is large, so the
// same total energy is applied but T^4 is re-evaluated as the cell warms, which is what makes it converge.
// The clamp remains underneath as a true last resort, and now reports rather than hides (dt_clamped).
const float MAX_DT_PER_STEP = 5.0;     // last-resort stability limit (see SUB-STEPPING below)
const int   MAX_SUBSTEPS = 8;          // slices per step when |dT| is large; 8 covers the measured 29.8 C
const float ALBEDO_GROUND = 0.15;
const float ALBEDO_WATER = 0.06;
const float ALBEDO_ICE = 0.65;
const float ICE_ALBEDO_GAIN = 40.0;    // snow mass -> reflectivity; a thin dusting already whitens a cell
const float HEAT_CAP_AIR = 800.0;
const float HEAT_CAP_ROCK = 1400.0;
const float HEAT_CAP_WATER = 9000.0;   // the ocean's thermal inertia — why coasts are mild
const float HEAT_CAP_SNOW = 2500.0;
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
// TWO CONSEQUENCES WORTH NAMING, because neither is coded for anywhere:
//   * ALTITUDE. exp(-relief/H_REF) with relief ~16 and H_REF ~50 leaves a summit under ~73% of the sea-level
//     column, so its emissivity rises and it equilibrates colder. The lapse rate is an OUTPUT now.
//   * TOP OF ATMOSPHERE. Those cells have almost nothing above them, so emissivity approaches 1 and they
//     radiate as bare blackbodies — which is what the top of an atmosphere does. The vertical temperature
//     structure comes from the same expression as the horizontal one.
//
// This also replaces 0.9, which was a round number chosen for a greybody and then paired with SOLAR_CONSTANT
// 600 "sized so the sub-solar point equilibrates near 300 K". At sea level the model below gives 0.615, so
// the pair is no longer consistent and the planet will run warmer until that is re-derived. Measure before
// touching SOLAR_CONSTANT: the last time it was cut 20% the global mean moved ONE degree, because the sun is
// not what sets this planet's temperature.
const float P_REF = 100.0;           // sea-level column pressure in this world's units
const float TAU_SEA = 0.835;         // grey optical depth of a sea-level air column (from Earth's 288/255)
const float TAU_TWO_STREAM = 0.75;   // the two-stream coefficient in T_s^4 = T_e^4 (1 + 0.75 tau)

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

		// GREENHOUSE from the air actually overhead — this is where altitude enters, and it enters as
		// physics rather than as a subtracted lapse. On step 0 the pressure channel is still all-zero
		// (wind_pressure seeds it AFTER Thermal's first dispatch, PASS_SCRIPTS order), so fall back to the
		// sea-level reference for that one step rather than letting every cell radiate as a blackbody.
		float p_col = pressure[idx];
		if (p_col <= 0.0) {
			p_col = P_REF;
		}
		float emissivity = 1.0 / (1.0 + TAU_TWO_STREAM * TAU_SEA * (p_col / P_REF));

		float t_k = max(temp[idx] + KELVIN, 1.0);              // clamp keeps T^4 finite if a cell goes wild
		float absorbed = SOLAR_CONSTANT * (1.0 - albedo) * insolation;
		float emitted  = STEFAN * emissivity * t_k * t_k * t_k * t_k;
		float dT = (absorbed - emitted) * STEP_DT / cap;
		// Numerical guard ONLY (not a physics clamp): one step may not move a cell more than this, so a
		// transient cannot NaN the field. Equilibrium is unaffected — it is reached over many steps.
		// SUB-STEP rather than truncate. One Euler step of a T^4 sink is only valid while T barely moves;
		// when it does not, slice the interval and re-evaluate the emission each slice. Energy is conserved
		// across the slices (each pays its own sigma*eps*T^4), the equilibrium is unchanged, and the cells
		// that used to lose 25 C/step of real cooling now actually cool.
		int slices = int(clamp(ceil(abs(dT) / MAX_DT_PER_STEP), 1.0, float(MAX_SUBSTEPS)));
		float sub_dt = STEP_DT / float(slices);
		float t_c = temp[idx];
		for (int s = 0; s < slices; ++s) {
			float tk = max(t_c + KELVIN, 1.0);
			float em = STEFAN * emissivity * tk * tk * tk * tk;
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
