#[compute]
#version 450

// CUBED-SPHERE PLATE TRANSPORT — THE CRUST ACTUALLY MOVES.
//
// LAPlateTectonics partitions the sphere into drifting Voronoi plates and rotates each about its own Euler
// pole. Until this kernel existed that rotation moved SEED POINTS and nothing else: the class never touched
// the material field, so the boundaries migrated across stationary continents and the "Ring of Fire" swept
// over ground that had never moved a metre. A plate that carries no crust is not a plate.
//
// WHAT THIS IS, AND WHAT IT IS NOT. It is TRANSPORT, not a phenomenon. There is no "rift", no "mountain", no
// "subduction zone" and no `if is_convergent` anywhere below. There is one rule — matter is carried by the
// velocity of the plate it sits on — applied to every cell of every channel it is dispatched over. What that
// rule DOES at a boundary is where the names come from and none of them is written down:
//   * plates parting  -> less arrives than leaves -> the crust THINS (a rift).
//   * plates closing  -> more arrives than leaves -> the crust THICKENS past a full cell, and the surplus has
//                        nowhere to go but radially outward, so the column grows upward (a mountain range).
//   * a coastline     -> the leading edge advances into the open cells ahead of it (a continent drifts).
// The uplift leg is the same universal rule as the lateral one: matter that no longer fits is displaced into
// the space that is available, and outward is the only direction with room. It is NOT mountain code.
//
// CONSERVATION IS THE POINT AND IT IS EXACT. Two-pass GATHER, structurally identical to
// erosion_transport_sphere3d.glsl and to the water/slump/lava CAs: pass 0 writes what leaves cell i along each
// of its six slots into `send[i*6+d]` (own-cell writes only); pass 1 sets fld = fld - own_out + inflow, where
// inflow reads each neighbour's send slot aimed back at me. What leaves equals what arrives EXACTLY, because
// both ends read the same `send` entry — that is what the grid's SLOT-OPPOSITE RECIPROCITY contract buys
// (LASphereGrid header: nbr[c*6+d]==m => nbr[m*6+(d^1)]==c, repaired at the cube-face seams). Nothing is ever
// sent toward a slot whose neighbour is -1, so the shell's inner and outer boundaries leak nothing.
//
// PASS 1 EDITS THE CHANNEL IN PLACE, which is what lets one kernel carry a SINGLE buffer (rock_fill) and a
// ping-pong half (sediment) with no extra allocation: pass 1 writes only fld[i] and reads only `send`, which
// nothing writes in pass 1, so it is a race-free own-cell read-modify-write.
//
// THE VELOCITY IS THE PLATE'S OWN. Each cell looks up its plate by the same sphere-Voronoi rule the CPU model
// uses to classify boundaries (nearest seed by angle), then takes v = omega x r for that plate's Euler pole.
// The cell's radius comes from its own index — the grid lays a column out as c = surf*depth + r, so
// r = c % depth and R = core_radius + (r + 0.5) * cell_size, with no per-cell lookup. Advection is DONOR-CELL
// UPWIND on the four lateral links: the fraction that leaves along link d is max(0, v . n_d) * dt / cell_size,
// with n_d the true world direction to that neighbour taken from `pos` (correct across the cube-face seams,
// where a tangent-frame shortcut would not be).
//
// CFL: at this planet's radius 500 and the fastest plate the model can draw, |v| dt / cell_size is under 0.02,
// so MAX_OUT_FRAC is a guard that never binds rather than a stability crutch. It is kept because the gather
// stays exactly conserving either way and because nothing should be able to empty a cell in one step.

layout(local_size_x = 64) in;

// The channel being carried. rock_fill (SINGLE) and sediment (a ping-pong half) are dispatched through the
// same pipeline with different uniform sets — the rule does not care which mineral phase it is moving.
// NOT `restrict`: when this pipeline carries rock_fill, bindings 0 and 7 are the SAME buffer (pass 2 needs
// solidity while pass 0/1 carry the rock), and two aliased `restrict` blocks are undefined behaviour.
layout(set = 0, binding = 0, std430) buffer Field { float fld[]; };
layout(set = 0, binding = 1, std430) restrict buffer Send { float send[]; };              // idx*6 + dir (shared scratch)
layout(set = 0, binding = 2, std430) restrict readonly buffer Radial { float radial[]; }; // per-cell outward unit vec, flat c*3+{0,1,2}
layout(set = 0, binding = 3, std430) restrict readonly buffer Pos { float pos[]; };       // per-cell world position, flat c*3+{0,1,2}
layout(set = 0, binding = 4, std430) restrict readonly buffer Neigh { int nbr[]; };       // idx*6 + slot
// PLATE TABLE, 8 floats per plate: seed.xyz (unit direction of the plate's Voronoi centre), rate (signed
// angular speed, rad per simulated second), pole.xyz (unit Euler axis), pad. Uploaded by the driver each step
// from LAPlateTectonics, which is the one owner of the kinematics — the same seeds it classifies boundaries with.
layout(set = 0, binding = 5, std430) restrict readonly buffer Plates { float plate[]; };
// The fluid the arriving rock has to push out of the way (see PASS 2). Bound for every dispatch but only
// touched by pass 2, which runs once per step after both mineral channels have been carried.
layout(set = 0, binding = 6, std430) restrict buffer Water { float water[]; };
layout(set = 0, binding = 7, std430) readonly buffer RockFill { float rock_fill[]; };   // see binding 0

layout(push_constant, std430) uniform Params {
	uint cell_count;
	uint pass_id;      // 0 = outflow into `send`, 1 = gather + apply in place, 2 = displace the buried fluid
	uint n_plates;     // 0 disables the whole pass (pass 0 sends nothing, pass 1 is then an exact no-op)
	uint depth;        // radial layers per column — gives a cell its radius from its own index
	float dt;
	float cell_size;
	float core_radius;
	float max_mass;    // a full cell of one phase (LAMaterialField3D.MAX_MASS); the surplus above it is uplifted
} params;

const float MAX_OUT_FRAC = 0.9;      // never empty a cell in one step (the gather stays exact either way)
const float MIN_MASS     = 1.0e-6;   // don't bother moving a numerically empty cell

vec3 cell_pos(uint i) {
	uint b = i * 3u;
	return vec3(pos[b + 0u], pos[b + 1u], pos[b + 2u]);
}

vec3 cell_radial(uint i) {
	uint b = i * 3u;
	return vec3(radial[b + 0u], radial[b + 1u], radial[b + 2u]);
}

// Sphere Voronoi: the plate whose seed direction is closest in angle. Identical rule to LAPlateModel._plate_of,
// so the crust that moves and the boundary that erupts are partitioned by ONE definition.
int plate_of(vec3 dir) {
	int best = 0;
	float best_dot = -2.0;
	for (uint k = 0u; k < params.n_plates; k++) {
		vec3 seed = vec3(plate[k * 8u + 0u], plate[k * 8u + 1u], plate[k * 8u + 2u]);
		float d = dot(dir, seed);
		if (d > best_dot) {
			best_dot = d;
			best = int(k);
		}
	}
	return best;
}

// How much liquid water a cell must give up because rock has closed over it. `solid` in this substrate is
// DERIVED as rock_fill >= 0.5, and a solid cell holds no water — so a cell the advancing crust has just made
// solid is exactly a cell whose water has to go somewhere. A pure function of that cell's own settled state,
// which is what makes the gather in pass 2 race-free: every thread that needs this number computes the same one.
float evicted(uint i) {
	return (rock_fill[i] >= 0.5) ? water[i] : 0.0;
}

// IS THIS CELL PART OF THE GROUND — is it rock, or is it resting directly on rock?
//
// THIS IS THE RULE THAT MAKES A PLATE A SLAB INSTEAD OF A SPRAY, and leaving it out was the single biggest
// error in the first version of this kernel. Lateral links join cells at the SAME RADIAL LAYER, and adjacent
// columns do not have their surfaces at the same layer — a mountain column's layer 12 is rock while its
// neighbour over the basin has open water there. Advecting on the raw lateral link therefore threw crust
// sideways into MID-AIR above the sea, where it landed as isolated partial fill that never reaches the 0.5
// solidity threshold, while the column it came from lost its top.
//
// Measured, seed 4242 at 600 frames, against the same build with the crust held still: `rock_cells` 31787 ->
// 28863, with 2460 units of bedrock stranded in open cells. Opening ~2900 cells of crust exposed the seeded
// geotherm, `hotspring_cells` went 309 -> 1310 and `hotspring_boiling` 190 -> 951, and the surface ocean
// flashed to steam behind it: `water_total` 1358 -> 223, `moisture_total` 2406 -> 3203. A TVD limiter was
// tried first on the theory that this was numerical diffusion smearing the coastline; it changed nothing
// (`rock_cells` 28863 either way), which is what identified the geometry rather than the scheme.
//
// The rule itself is gravity, not geology: matter has to have something under it. Rock shoved into open space
// with nothing beneath it falls, and this substrate has no rock-fall, so the honest thing is that the flux
// does not go there at all — the plate is buttressed and its motion is blocked in that direction. Conserving
// either way, because a flux that is not sent stays in the donor cell. Nothing here mentions a coastline.
bool supported(int c) {
	if (c < 0) {
		return false;
	}
	if (rock_fill[uint(c)] >= 0.5) {
		return true;
	}
	int dn = nbr[uint(c) * 6u + 0u];
	return dn >= 0 && rock_fill[uint(dn)] >= 0.5;
}

void main() {
	uint gidx = gl_GlobalInvocationID.x;
	if (gidx >= params.cell_count) {
		return;
	}
	uint base = gidx * 6u;

	if (params.pass_id == 2u) {
		// ---- PASS 2: THE ROCK PUSHES THE WATER OUT OF THE WAY -------------------
		// A continent advancing into a basin arrives in cells that hold sea. Without this the water was
		// ENTOMBED: the cell went solid, the water CA skips solid cells, and the mass sat there unreachable.
		// Measured before this pass existed, seed 4242 at 600 frames: `h2o_buried` 1527.2 against a baseline
		// 0.01, and `water_total` fell from 1358 to 214 — the plates drank the ocean.
		//
		// It is the SAME universal rule as the uplift leg: matter that no longer fits is displaced into the
		// space that is available, and for a fluid under arriving rock that direction is up. Archimedes, not a
		// coastline rule — nothing here knows what a sea is.
		//
		// GATHER FORM, so it conserves and cannot race: a cell loses its own eviction and gains its INWARD
		// neighbour's, both computed from settled post-advection state that pass 2 does not modify. One shell
		// per step, which makes a deep burial a relaxation over a few steps rather than an instant lift.
		float out_w = evicted(gidx);
		int dn = nbr[base + 0u];
		float in_w = (dn >= 0) ? evicted(uint(dn)) : 0.0;
		water[gidx] = max(0.0, water[gidx] - out_w + in_w);
		return;
	}

	if (params.pass_id == 0u) {
		// ---- PASS 0: OUTFLOW ----------------------------------------------------
		// Self-zero all six slots before any early return, exactly like the other CAs, so the shared `send`
		// scratch needs no buffer_clear (illegal while a compute list is open).
		send[base + 0u] = 0.0;
		send[base + 1u] = 0.0;
		send[base + 2u] = 0.0;
		send[base + 3u] = 0.0;
		send[base + 4u] = 0.0;
		send[base + 5u] = 0.0;
		if (params.n_plates == 0u) {
			return;
		}
		float load = fld[gidx];
		if (load < MIN_MASS) {
			return;
		}
		if (!supported(int(gidx))) {
			return;    // not part of the ground — a plate carries the slab, not whatever is floating over it
		}

		// This cell's plate velocity: v = omega x r, with r from the cell's own radial layer.
		vec3 rad = cell_radial(gidx);
		float R = params.core_radius + (float(gidx % params.depth) + 0.5) * params.cell_size;
		int k = plate_of(rad);
		vec3 omega = vec3(plate[uint(k) * 8u + 4u], plate[uint(k) * 8u + 5u], plate[uint(k) * 8u + 6u])
			* plate[uint(k) * 8u + 3u];
		vec3 v = cross(omega, rad * R);

		// UPWIND ADVECTION on the four lateral links, WITH A MINMOD FLUX LIMITER. `pos` gives the true world
		// direction to each neighbour, which stays correct where a cube face meets another and the tangent
		// frames disagree.
		//
		// THE LIMITER IS WHY CONTINENTS DRIFT INSTEAD OF DISSOLVING, and plain donor-cell was measured doing
		// the latter. First-order upwind carries a numerical diffusion of u*dx*(1-C)/2 per step, so a coastline
		// smears as sqrt(t) while it travels as t: at 2.5 cells of motion over 590 steps the smear is 2.2 cells,
		// i.e. as wide as the displacement. That is not cosmetic here, because `solid` is DERIVED as
		// rock_fill >= 0.5 — smeared crust falls BELOW the threshold and the cell OPENS. Measured on the
		// unlimited scheme, seed 4242 at 600 frames: `rock_cells` 29291 against 31787 with the crust held
		// still, 2074 units of bedrock stranded in sub-solid open cells, `hotspring_cells` 4x baseline as the
		// opened crust exposed the geotherm, and the ocean flashed to steam behind it. The continents did not
		// move; they evaporated.
		//
		// So the face value is reconstructed with a slope instead of taken as the donor cell's own value:
		//   face = q_i + 0.5*(1 - C)*psi(r)*(q_down - q_i),   r = (q_i - q_up)/(q_down - q_i)
		// with minmod psi = clamp(r, 0, 1). `q_up` is the cell BEHIND i along the same axis, which the grid
		// hands over for free: lateral slots pair 1<->2 and 3<->4, the same reciprocity the gather below relies
		// on. minmod is TVD, so this sharpens the front without inventing an overshoot, and the flux is still
		// ONE number per link, so the gather stays exactly conserving.
		vec3 p0 = cell_pos(gidx);
		float raw[4];
		float lateral = 0.0;
		for (int d = 0; d < 4; d++) {
			raw[d] = 0.0;
			int inb = nbr[base + 1u + uint(d)];
			if (inb < 0 || !supported(inb)) {
				continue;    // nothing to land on that way — the slab is buttressed, the flux is blocked
			}
			vec3 step_v = cell_pos(uint(inb)) - p0;
			float len = length(step_v);
			if (len < 1.0e-6) {
				continue;
			}
			float u = dot(v, step_v / len);
			if (u <= 0.0) {
				continue;
			}
			float courant = u * params.dt / max(params.cell_size, 1.0e-6);
			float face = load;
			float down = fld[uint(inb)] - load;                 // gradient ahead of the front
			if (abs(down) > 1.0e-9) {
				// The opposite lateral slot is this axis's other direction: 1<->2, 3<->4.
				int opp = int(1u + (uint(d) ^ 1u));
				int iup = nbr[base + uint(opp)];
				float behind = (iup >= 0) ? (load - fld[uint(iup)]) : 0.0;
				float r = behind / down;
				float psi = clamp(r, 0.0, 1.0);                 // minmod
				face = load + 0.5 * (1.0 - courant) * psi * down;
			}
			raw[d] = courant * max(face, 0.0) / max(load, 1.0e-9);
			lateral += raw[d];
		}

		// UPLIFT. A cell holding more than one full phase-cell has surplus matter with nowhere lateral to go;
		// the only room is outward, so it goes there, limited by what the cell above can still hold. This is the
		// same displacement rule as the lateral leg, not a landform: run it where plates converge and the column
		// grows upward, which is what a mountain range IS.
		float up_out = 0.0;
		float excess = max(0.0, load - params.max_mass);
		if (excess > MIN_MASS) {
			int up = nbr[base + 5u];
			if (up >= 0) {
				up_out = min(excess, max(0.0, params.max_mass - fld[uint(up)]));
			}
		}

		// Total outflow may never exceed what the cell holds (nor MAX_OUT_FRAC of it). Scale both legs together
		// so the split between them is preserved and the gather stays exactly conserving.
		float total = lateral * load + up_out;
		float cap = MAX_OUT_FRAC * load;
		float scale = (total > cap && total > 0.0) ? (cap / total) : 1.0;
		send[base + 1u] = load * raw[0] * scale;
		send[base + 2u] = load * raw[1] * scale;
		send[base + 3u] = load * raw[2] * scale;
		send[base + 4u] = load * raw[3] * scale;
		send[base + 5u] = up_out * scale;
		return;
	}

	// ---- PASS 1: GATHER / APPLY IN PLACE ----------------------------------------
	// Reads only `send` (written in pass 0, untouched here) and writes only its own cell.
	float own_out = send[base + 0u] + send[base + 1u] + send[base + 2u]
		+ send[base + 3u] + send[base + 4u] + send[base + 5u];

	float inflow = 0.0;
	int nb;
	nb = nbr[base + 0u]; if (nb >= 0) { inflow += send[uint(nb) * 6u + 5u]; }  // down-neighbour sent UP (5)
	nb = nbr[base + 5u]; if (nb >= 0) { inflow += send[uint(nb) * 6u + 0u]; }  // up-neighbour sent DOWN (0)
	nb = nbr[base + 1u]; if (nb >= 0) { inflow += send[uint(nb) * 6u + 2u]; }  // -a neighbour sent +a (2)
	nb = nbr[base + 2u]; if (nb >= 0) { inflow += send[uint(nb) * 6u + 1u]; }  // +a neighbour sent -a (1)
	nb = nbr[base + 3u]; if (nb >= 0) { inflow += send[uint(nb) * 6u + 4u]; }  // -b neighbour sent +b (4)
	nb = nbr[base + 4u]; if (nb >= 0) { inflow += send[uint(nb) * 6u + 3u]; }  // +b neighbour sent -b (3)

	fld[gidx] = max(0.0, fld[gidx] - own_out + inflow);
}
