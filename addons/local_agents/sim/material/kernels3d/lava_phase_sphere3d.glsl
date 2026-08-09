#[compute]
#version 450

// CUBED-SPHERE lava THERMAL RADIATION — an exposed molten cell emits, at the temperature it is actually at.
// Runs AFTER lava_flow_sphere3d, in place on the post-flow lava + temp buffers. Rock unification Stage B
// DISSOLVED the SOLIDIFY leg into the M5 DEFS reaction record (cold lava -> rock_fill, a conserving own-cell
// transfer), so this kernel does NOT write `solid` (now DERIVED from rock_fill by solid_derive_sphere3d.glsl)
// and does NOT zero lava. What is left is one physical process:
//
//   RADIATION. Molten basalt at 1100-1200 C is very nearly a blackbody in the thermal infrared, so it sheds
//   heat by EMITTING it — sigma * epsilon * T^4 from every face that opens onto something it can radiate
//   into, net of what that neighbour radiates back. Nothing else in this kernel touches temperature.
//
// *(Rewritten 2026-08-07. WHAT THIS REPLACED, and why it had to go: a Newtonian relax toward a prescribed
//  ambient.
//      const float LAVA_AMBIENT   = 40.0;    // the temperature lava was pulled toward
//      const float LAVA_COOL_RATE = 0.05;    // the rate it was pulled at
//      const float EXPOSURE_GAIN  = 1.0;     // ...scaled up by how many faces were "exposed"
//      cool_k = LAVA_COOL_RATE * clamp(EMPLACE_DEPTH / d, 0.25, 3.0) * (1.0 + EXPOSURE_GAIN * exposed);
//      cooled = max(LAVA_AMBIENT, temp[g] - cool_k * (temp[g] - LAVA_AMBIENT));
//  Three of those four numbers are properties of nothing. 40 C is not a temperature of the sky, of the air,
//  or of anything a lava flow touches; 0.05 and 1.0 are rates chosen to make flows harden at a rate that
//  looked right. NO CELL RECEIVED THE HEAT and no gauge could see it leave, so it was heat DELETED, every
//  step, at every exposed molten cell — the same defect the BURIED leg's HOT_ROCK_AMBIENT = 780 was deleted
//  for at 2026-08-03, and it survived that pass only because the exposed case was argued to be "genuine loss
//  from the surface energy budget". A fitted relax toward a fitted target is not emission. It has no flux, so
//  it cannot appear in an energy budget, and the planet's books could not see 1150 C rock cooling by up to
//  333 C in a single step.
//
//  MEASURED, so the size of the change is on the record. At the old constants a cell at 1150 C with five
//  exposed faces lost 333 C/step; with one exposed face, 111 C/step. The real radiative rate for the same
//  cell is 0.245 C/step per emitting face (the arithmetic is in the CONSTANTS block). The old model was
//  450-1400x too fast.)*
//
// WHAT A "SHELL-FIRST" FLOW IS NOW, AND WHY EXPOSURE_GAIN IS GONE RATHER THAN RESCALED. The old kernel
// counted EXPOSED faces and multiplied a cooling rate by that count, so a flow's outer rind hardened while
// its core stayed molten and drained — a lava tube, produced by a gain constant. The net grey exchange makes
// that same behaviour a CONSEQUENCE and needs no count at all: a face looking at 20 C air carries the full
// sigma*eps*(T^4 - T_air^4), while a face looking at another 1150 C lava cell carries sigma*eps*(T^4 - T^4)
// = ZERO. Interior faces stop radiating because their neighbour is as hot as they are, which is the physical
// reason a flow interior stays molten, and it is exact rather than tuned. The face classification loop, the
// `exposed`/`open_faces` counters and EXPOSURE_GAIN all went with it.
//
// THE DEPTH TERM IS GONE THE SAME WAY. `clamp(EMPLACE_DEPTH / d, 0.25, 3.0)` existed so "a deep pool retains
// heat longer than a thin crust". It does, and the reason is thermal inertia: the cell's heat capacity is the
// volumetric heat capacity of the molten rock it holds. `d` (the lava fill fraction) now enters through the
// capacity and through the emitting AREA, where it belongs, and EMPLACE_DEPTH is deleted.
//
// A CELL FULLY ENCLOSED BY ROCK STILL DOES NOTHING HERE, and now for a stated reason rather than an early
// return: rock is opaque, so a rock-facing face radiates nowhere and contributes no term. Its heat leaves by
// CONDUCTION into the surrounding rock, which heat_sphere3d.glsl performs conservatively with the real
// thermal conductivities.
//
// WHAT WAS REUSED FROM heat3d_solar_sphere3d.glsl:404-472 rather than re-invented (that kernel owns the
// planet's surface radiation and this one must not be a second, disagreeing radiation model):
//   * the NET two-layer grey form `emitted = <own faces> * sigma * T^4 - lw_in`, with the partner's
//     contribution accumulated once outside the integration and held constant across it;
//   * `t_k = max(T + KELVIN, 1.0)` before the fourth power, so a wild cell cannot produce a non-finite flux;
//   * areal heat capacity `cap = rho*c * cell_size`, and `dT = flux * dt_s / cap` on the same pushed real
//     seconds every other kernel in this pass runs on;
//   * the SUB-STEPPING integrator. One Euler step of a T^4 sink is only valid while T barely moves, so the
//     interval is sliced when the implied change is large and the emission re-evaluated each slice. Same
//     MAX_DT_PER_STEP / MAX_SUBSTEPS pair, same last-resort clamp underneath.
// What is NOT reused is that kernel's EMITTER: it radiates a grey ATMOSPHERE over a surface, this one
// radiates BASALT, so the emissivity is LAPhysical.BASALT_EMISSIVITY and not a two-stream optical depth.
//
// KNOWN OVERLAP, stated rather than hidden. heat3d_solar_sphere3d.glsl also emits from a molten cell when
// that cell is its column's MATERIAL SURFACE (open, resting on rock, clear sky above), so the outward face of
// such a cell is radiated from twice — once there as a unit-emissivity blackbody, once here as basalt. The
// far larger error at those same cells is in that kernel's `rc_of_cell`, which builds a cell's heat capacity
// from rock_fill/water/snow/air and DOES NOT INCLUDE `lava`: a cell that is entirely molten rock has
// rock_fill 0 (add_lava moved it) and so reads as AIR, 1186 J/m^3/K against molten rock's ~2.4e6, a factor of
// 2054, which makes its 5 C/step limiter bind on every exposed lava cell. Both belong to that kernel and to
// the shared heat-capacity mix, not here.
//
// Neighbour reads use the precomputed INDEX TABLE nbr[idx*6 + d] (slot 0 = inward/down, 1-4 lateral, 5 =
// outward/up; -1 = boundary).

layout(local_size_x = 64) in;

// COMPACTED DISPATCH. This kernel is dispatched INDIRECTLY, with one invocation per ACTIVE cell rather than
// one per grid cell: it reads its cell id out of `active_idx` and its loop bound out of `active_args[3]`, both
// built the same step by cell_list_lava_sphere3d.glsl. That kernel evaluates, verbatim, the two
// side-effect-free early-outs this one used to open with (lava < LAVA_MIN_MASS, solid != 0), which is why they
// are gone from below. The predicate is PHYSICAL — "this cell holds molten rock in open space" — so the list
// is the same at any camera position.
//
// THE WRITER SET IS UNCHANGED, which is the honest claim — not "bit-identical". The radiative exchange below
// READS neighbours (temp[nb], solid[nb]) while other threads write temp[g] to the same buffer, so this
// kernel's output was never bit-reproducible and compaction changes which threads are co-resident. That race
// is pre-existing and the distribution is unaffected because exactly the same cells write exactly the same
// values; what compaction cannot do is introduce NEW nondeterminism. It can only ever make the emission
// slightly too small or too large through a stale `temp[nb]`, never change its sign: the net is floored at
// zero below, so a racy read cannot turn this kernel into a heat SOURCE.
layout(set = 0, binding = 0, std430) restrict buffer Lava { float lava[]; };
layout(set = 0, binding = 1, std430) restrict buffer Temp { float temp[]; };
layout(set = 0, binding = 2, std430) restrict buffer Solid { float solid[]; };
layout(set = 0, binding = 4, std430) restrict readonly buffer ActiveIdx { uint active_idx[]; };
layout(set = 0, binding = 5, std430) restrict readonly buffer ActiveArgs { uint active_args[]; };
layout(set = 0, binding = 15, std430) restrict readonly buffer Neigh { int nbr[]; };   // idx*6 + slot

layout(push_constant, std430) uniform Params {
	uint cell_count;   // only a defensive bound on the id read out of active_idx
	// REAL seconds one field step represents (LAMaterialFieldSphereStep3D.real_seconds_per_step, 43.2 at the
	// shipped 200 s day) and the grid cell edge in METRES (LASphereGrid.cell_size, 16.0 on the shipped
	// 500-radius planet). Both took what were pad0/pad1 when this kernel had no dt and no length scale to
	// speak of, because a relax rate needs neither. A FLUX does: it is W/m^2, and turning it into a
	// temperature needs the step's real duration and the depth of matter behind the face. They are PUSHED and
	// not hardcoded for the same reason heat3d_solar_sphere3d.glsl pushes them — they are properties of this
	// world's time compression and of this grid, not of basalt, and they must re-derive at another
	// resolution or day length. If either arrives as 0 this kernel radiates nothing at all, which is the one
	// failure mode to watch for when changing ThermalPass._lava_phase_pc.
	float dt_s;
	float cell_size;
	uint pad2;
} params;

// --- MODEL PARAMETERS -------------------------------------------------------------------------------------
// Properties of this substrate and of this integrator, not of matter. MUST match MaterialLava3D.gd /
// cell_list_lava_sphere3d.glsl where noted.
const float LAVA_MIN_MASS = 0.0001;
// The temperature below which this kernel stops calling a cell molten and hands it to the M5 solidify record.
// It matches reactions/PhaseRecords.gd's SOLIDIFY_TEMP, which is the record that actually performs
// lava -> rock_fill, and the two must not drift apart or a band opens where neither acts.
//
// IT DISAGREES WITH THE AUTHORITY AND THAT IS A REAL DEFECT, LEFT HERE ONLY BECAUSE IT CANNOT BE FIXED ON ONE
// SIDE. PhysicalConstants.gd puts basalt's solidus at 1000 C, citing that basaltic lava "becomes fully solid
// below its solidus"; both copies of this constant say 800. So a cell between 800 and 1000 C is treated as
// molten by this kernel and by the M5 record while the material it is made of is already solid rock. Moving
// only this copy to 1000 would open a 200 C band in which this kernel returns early (nothing radiates) and M5
// has not yet frozen the cell (nothing solidifies), which is worse than the disagreement. Both copies have to
// move in one change, and the second lives in a file this pass does not own. The physical-constants gate does
// not catch it: its name heuristic skips anything carrying SOLIDIF, ROCK, BASALT or LAVA on the grounds that
// those are not water's phase points, which is right in general and blind here.
const float SOLIDIFY_TEMP = 800.0;
// STABILITY, reused verbatim from heat3d_solar_sphere3d.glsl along with the sub-stepping loop it belongs to.
// One Euler step of a T^4 sink is only valid while T barely moves; when the implied change is large the
// interval is sliced and the emission re-evaluated per slice, so the same energy is applied but the result
// converges instead of being truncated. The clamp survives underneath as a genuine last resort.
const float MAX_DT_PER_STEP = 5.0;
const int   MAX_SUBSTEPS = 8;

// --- MEASURED PROPERTIES OF MATTER ------------------------------------------------------------------------
// THE MAGNITUDE THIS PRODUCES, worked once so a wrong one is recognisable. A 1150 C (1423.15 K) basalt face
// at emissivity 0.95 radiates sigma*eps*T^4 = 5.670374419e-8 * 0.95 * 1423.15^4 = 2.21e5 W/m^2, i.e. 221
// kW/m^2, which is what a thermal camera measures on an open channel of fresh basalt. Against a full cell of
// molten rock 16 m deep — 2.436e6 * 16 = 3.90e7 J/m^2/K — one 43.2 s step is 2.21e5 * 43.2 / 3.90e7 = 0.245 C
// of cooling per emitting face. Six faces would be 1.47 C/step.
//
// WHAT THAT SAYS ABOUT THIS GRID, because it is a finding and not a disappointment. Cooling a 16 m cell from
// 1150 C to the solidus takes ~350 C, so an all-faces-exposed cell needs ~240 steps (2.9 simulated hours) and
// a single-face one ~1400. That is CORRECT for 16 m of basalt: a real flow of that thickness takes days to
// weeks to solidify through. What a real flow does in seconds is skin over, and that skin is millimetres
// thick — three to four orders of magnitude below this grid's cell. A 16 m voxel cannot resolve a lava crust,
// and the old EXPOSURE_GAIN was buying the APPEARANCE of one by cooling the whole 16 m at the rate its first
// millimetre cools. If a visible crust is wanted it has to come from resolution or from a sub-cell skin
// model, never from putting the gain back.
const float STEFAN = 5.670374419e-8;   // LAPhysical.STEFAN_BOLTZMANN
const float BASALT_EMIS = 0.95;        // LAPhysical.BASALT_EMISSIVITY — fresh basalt is near-black in the IR
const float KELVIN = 273.15;           // LAPhysical.KELVIN_OFFSET — T^4 is in KELVIN, and this is the whole
                                       // difference between 221 kW/m^2 and 8 kW/m^2 at an erupting temperature
// Volumetric heat capacities, the same pair heat_sphere3d.glsl / heat3d_solar_sphere3d.glsl /
// heat3d_buoyancy_sphere3d.glsl use, so the same cell holds the same heat in every kernel that touches it.
//
// MOLTEN basalt is not solid basalt and the authority does not yet separate them: melt runs rho ~2700 kg/m^3
// against c_p ~1200 J/kg/K, so ~3.2e6 J/m^3/K, about 33% ABOVE the solid figure used here. Using the solid
// value therefore cools lava slightly FASTER than reality, which is the conservative direction for a kernel
// whose whole job is a sink. A VOL_HEAT_CAP_MAGMA_J_M3K belongs in PhysicalConstants.gd with its citation;
// adding it is a change to a file this pass does not own.
const float RC_LAVA = 2.436e6;         // LAPhysical.VOL_HEAT_CAP_ROCK_J_M3K
const float RC_AIR = 1186.0;           // LAPhysical.VOL_HEAT_CAP_AIR_J_M3K

void main() {
	// One invocation per ACTIVE cell. `active_args[3]` is the compacted list length; the trailing invocations
	// of the last workgroup (and the single idle group dispatched when the list is empty) fall out here.
	uint t = gl_GlobalInvocationID.x;
	if (t >= active_args[3]) {
		return;
	}
	uint g = active_idx[t];
	if (g >= params.cell_count) {
		return;                     // defensive: a corrupt list must not scribble outside the grid
	}
	// lava >= LAVA_MIN_MASS and solid == 0 were both applied by cell_list_lava_sphere3d.glsl when it appended
	// this cell, so a listed cell has already passed them.
	if (temp[g] < SOLIDIFY_TEMP) {
		// Below the solidus this is no longer molten rock and this kernel's emitter does not describe it. It
		// is left alone so the M5 solidify record sees the genuine post-thermal cold and freezes it to
		// rock_fill; from then on the shared thermal kernels own its radiation and conduction, as they do for
		// any other rock.
		return;
	}

	// THE EMITTING AREA is the molten rock in the cell, not the whole face. `lava` is a FILL FRACTION of the
	// cell volume (lava_flow_sphere3d.glsl MAX_MASS = 1.0, and add_lava moves rock_fill into it one for one),
	// so a cell one hundredth full of lava presents a hundredth of a basalt face to its neighbours. Both the
	// outgoing and the returning term scale with it, so it factors out of the exchange and is applied once.
	//
	// This is also what keeps the kernel well behaved on a thin flow. Without it a cell at f = 0.01 would
	// radiate a full basalt face against a hundredth of the thermal inertia and cool 23 C in a step; with it
	// the two scale together and the rate lands at 0.234 C/step against a full cell's 0.245 — a thin sheet
	// and a deep pool cool at nearly the same rate per unit of their own mass, which is the physical answer.
	float f_lava = clamp(lava[g], 0.0, 1.0);
	// AREAL heat capacity of what the cell holds: volumetric rho*c of the mix, times the cell's own depth.
	// Only lava and air are available here (water, snow and rock_fill are not bound to this pass), so a wet or
	// partly-bedrock cell carries more inertia than this says and cools slower than this makes it — again the
	// conservative direction. A SUBMERGED molten cell is the case where that matters, and it is handled
	// upstream: heat3d_cool_sphere3d.glsl charges the latent heat of vaporisation against the seawater such a
	// cell boils, which is what quenches it to pillow basalt in a few steps.
	float cap = max((RC_LAVA * f_lava + RC_AIR * (1.0 - f_lava)) * params.cell_size, 1.0);

	// Classify this cell's 6 faces ONCE. A face radiates if there is somewhere for the radiation to go:
	//   * nbr < 0  — the domain boundary, i.e. space. Nothing comes back (the 2.7 K microwave background is
	//                3e-6 W/m^2, eleven orders below the outgoing term).
	//   * solid    — rock. Opaque in both directions, so no radiative term at all; heat_sphere3d.glsl carries
	//                this bond by conduction and gives the rock exactly what the lava loses.
	//   * open     — air, water or another lava cell. It radiates back at its own temperature, and that
	//                return is what makes an interior face between two equally hot cells carry nothing.
	uint base = g * 6u;
	float faces = 0.0;      // how many faces emit, in units of a whole cell face
	float lw_in = 0.0;      // W/m^2 returning across those faces, held constant across the sub-steps
	for (int i = 0; i < 6; i++) {
		int nb = nbr[base + uint(i)];
		if (nb < 0) {
			faces += 1.0;
			continue;
		}
		if (solid[nb] != 0.0) {
			continue;
		}
		faces += 1.0;
		float tn = max(temp[nb] + KELVIN, 1.0);
		lw_in += BASALT_EMIS * STEFAN * tn * tn * tn * tn;
	}
	if (faces == 0.0) {
		return;             // sealed in rock: nothing to radiate into, and conduction already owns it
	}

	// SUB-STEPPED T^4 SINK, the integrator from heat3d_solar_sphere3d.glsl. Size the slicing from the change
	// the first evaluation implies, then re-evaluate the emission as the cell cools so the result converges on
	// the same energy instead of being truncated at the clamp.
	float t_c = temp[g];
	float tk0 = max(t_c + KELVIN, 1.0);
	float dt0 = f_lava * (faces * BASALT_EMIS * STEFAN * tk0 * tk0 * tk0 * tk0 - lw_in) * params.dt_s / cap;
	int slices = int(clamp(ceil(abs(dt0) / MAX_DT_PER_STEP), 1.0, float(MAX_SUBSTEPS)));
	float sub_dt = params.dt_s / float(slices);
	for (int s = 0; s < slices; ++s) {
		float tk = max(t_c + KELVIN, 1.0);
		float em = f_lava * (faces * BASALT_EMIS * STEFAN * tk * tk * tk * tk - lw_in);
		// FLOORED AT ZERO, and this is the kernel's one invariant: emission may only ever LOWER a cell's
		// temperature. A neighbour hotter than this cell does warm it in reality, but it warms it by radiating
		// — which is that neighbour's own emission, computed by its own invocation of this kernel, and adding
		// it here as well would count the same photons twice. It also makes the pre-existing in-place race on
		// `temp[nb]` harmless: a stale read can move the magnitude, never the sign.
		t_c -= clamp(max(em, 0.0) * sub_dt / cap, 0.0, MAX_DT_PER_STEP);
	}
	temp[g] = t_c;
}
