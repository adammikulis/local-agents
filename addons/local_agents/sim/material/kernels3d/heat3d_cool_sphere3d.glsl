#[compute]
#version 450

// CUBED-SPHERE heat EVAPORATIVE-COOLING pass — sphere port of heat3d_cool3d.glsl (heat3d_cool.glsl, box).
// Runs LAST in the heat chain, IN PLACE on the temp buffer, reading the POST-FLOW water (a wet cell sheds
// heat toward the sea target so rivers/sea act as a heat sink + firebreak). Purely per-cell independent.
//
// DEPTH ON THE SPHERE: the box derived a thermocline target from the cell's world height wy = origin_y +
// iy*cell_size, then depth = max(0, sea_level - wy). On the cubed sphere "up" is the OUTWARD RADIAL, so the
// physically-correct depth is measured against the sea RADIUS, not a Y plane. This kernel therefore reads the
// cell's world position (bound Pos buffer) and uses its RADIUS (= length(pos)) in place of wy, with the sea
// surface given as a radius (sea_radius). The sea_water_target curve itself is byte-for-byte the box's
// (warm skin near the surface decaying to the cold deep floor across THERMOCLINE_SCALE). This is the one
// non-trivial change; everything else — the wet-cell gate, the knife-edge water >= 0.05 test, the relax
// math — is IDENTICAL. The constants originated in MaterialHeat3D.gd, which no longer exists (nor does any
// box kernel: kernels3d/ holds only *_sphere3d.glsl now), so this file is their sole home. Nothing is left
// to keep them in sync with; edit them here.

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict buffer Temp { float temp[]; };
layout(set = 0, binding = 1, std430) restrict readonly buffer Water { float water[]; };
layout(set = 0, binding = 2, std430) restrict readonly buffer Solid { float solid[]; };
layout(set = 0, binding = 3, std430) restrict readonly buffer Pos { vec4 cell_pos[]; };   // world position per cell (xyz)
layout(set = 0, binding = 4, std430) restrict readonly buffer Lava { float lava[]; };      // molten mineral per cell

layout(push_constant, std430) uniform Params {
	uint cell_count;
	float sea_radius;   // world radius of the sea surface (replaces the box's planar sea_level)
	float pad0;
	float pad1;
} params;

// Constants — AUTHORITATIVE HERE, no mirror to match.
// (Corrected 2026-07-29: this line said "MUST match MaterialHeat3D.gd exactly". That file is deleted, so the
// instruction sent readers looking for a mirror that does not exist and implied a parity contract that ended
// when the CPU heat module did.)
//
// WARNING, and the reason this is not merely a stale comment: SST_SURFACE / WATER_TEMP_DEEP make the ocean a
// THERMOSTAT, not a body of water. Every wet cell is dragged toward this fixed profile, so sea-surface
// temperature is 26 °C by fiat at every latitude, in every season, forever — it cannot respond to insolation,
// to an impact winter, or to a volcano. That, plus the absence of any radiative sink (nothing here computes
// T^4 emission to space; heat3d_solar relaxes toward a target instead), is why FREEZE_TEMP had to be moved to
// 12.5 °C in MaterialReactions3D.gd and why arc volcanoes are kept artificially rare in PlateTectonics.gd.
// Replacing this with a real energy balance is tracked as the radiative-sink work in HANDOFF.md.
const float WATER_COOL_RATE = 0.12;
const float SST_SURFACE = 26.0;
const float WATER_TEMP_DEEP = 10.0;
const float THERMOCLINE_SCALE = 24.0;

// SUBMERGED-LAVA QUENCH (seabed-volcano capstone). Molten rock (lava) meeting seawater is a VIOLENT heat sink —
// the water flashes to steam and the lava rinds over in an instant (pillow lava). The gentle WATER_COOL_RATE that
// suffices for a wet firebreak cannot beat lava_phase's 950°C sustain floor (it relaxes a 950°C cell only to
// ~838°C, above the 800°C solidus, so it oscillates and NEVER freezes). So a wet cell carrying lava relaxes toward
// the cold sea target at a MUCH stronger fraction, dropping it under the solidus in ONE step so the M5 record
// downstream freezes it to rock_fill. This is the universal "water quenches molten rock" property — it makes EVERY
// underwater lava flow quench fast (pillow basalt, seamounts, and the island the seabed vent builds), not a
// volcano special case. Above water there is no such term, so subaerial flows stay hot and creep (unchanged).
const float LAVA_QUENCH_MIN = 0.02;     // a wet cell with at least this much molten mineral quenches hard
const float LAVA_QUENCH_FRAC = 0.7;     // fraction of the gap to the cold sea target closed per step (950->~296)

// HOT-SPRING GATE. A wet cell ABOVE sea level that is far HOTTER than the marine (SST) target is not a
// solar-warmed river or the sea surface — it is a geothermal SPRING: groundwater that surfaced through hot
// rock (the soil pass's carry-heat). Relaxing it toward the ~26°C SST target at the full marine rate would
// QUENCH it before the boiling/evap kernel ever sees ~100°C, so a hot land cell sheds heat MUCH slower here
// (it still loses heat to conduction + the latent-heat sink of evaporation/boiling, which is the physical way
// a spring cools). The sea, and ordinary-temperature land water near the target, relax at the full rate.
const float HOT_SPRING_MARGIN = 15.0;   // °C above the marine target beyond which a LAND cell counts as a spring
const float HOT_SPRING_COOL_FRAC = 0.06; // hot land springs relax ~16x slower than the marine rate

// Sea thermal profile (formerly mirrored by MaterialHeat3D.sea_water_target(), now deleted — this is the only
// copy): a warm skin near the surface decaying
// with depth toward the cold deep floor (thermocline). On the sphere `wy` is the cell RADIUS and `sea` the
// sea-surface RADIUS, so `depth = max(0, sea - radius)` is the radial depth below the surface — the exact
// analog of the box's height-below-sea-level. The math is unchanged.
float sea_water_target(float wy, float sea) {
	float depth = max(0.0, sea - wy);
	return WATER_TEMP_DEEP + (SST_SURFACE - WATER_TEMP_DEEP) * exp(-depth / THERMOCLINE_SCALE);
}

void main() {
	uint idx = gl_GlobalInvocationID.x;
	if (idx >= params.cell_count) {
		return;
	}
	// The CPU oracle tests `water > 0.05` in FLOAT64 (GDScript widens the float32 cell to double). In
	// float32 the smallest value that widens to > 0.05 is exactly 0.05f itself, so `>= 0.05` in float32 is
	// provably identical to the oracle's float64 `> 0.05` for EVERY float32 input — this restores parity
	// at the knife-edge cell where post-flow water lands on exactly 0.05.
	if (solid[idx] == 0.0 && water[idx] >= 0.05) {
		float radius = length(cell_pos[idx].xyz);
		float wt = sea_water_target(radius, params.sea_radius);
		if (lava[idx] > LAVA_QUENCH_MIN) {
			// Molten mineral in seawater: quench HARD toward the cold sea target so it drops under the 800°C
			// solidus this step and the M5 record freezes it to rock — the seabed volcano's island-builder.
			temp[idx] = mix(temp[idx], wt, LAVA_QUENCH_FRAC);
		}
		// THE OCEAN THERMOSTAT IS GONE, and with it the hot-spring gate that existed only to escape it.
		//
		// Every wet cell used to be dragged toward a hardcoded thermocline (SST_SURFACE 26 C at the surface
		// decaying to WATER_TEMP_DEEP 10 C), so sea-surface temperature was 26 C by fiat at every latitude, in
		// every season, forever — it could not respond to insolation, to an impact winter, or to a volcano.
		// A HOT_SPRING_GATE had to be invented on top of it because that thermostat would otherwise quench a
		// geothermal spring before the boiling kernel ever saw 100 C. Both are deleted here.
		//
		// Water's thermal behaviour now comes from what water actually is: a very high heat capacity in the
		// surface energy balance (HEAT_CAP_WATER, an order above rock), plus conduction. That is what makes an
		// ocean lag the land beside it and a coast mild, rather than a curve asserting it. The LAVA QUENCH
		// above stays — water flashing molten rock to pillow basalt is real physics, not a stand-in.
	}
}
