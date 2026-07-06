#[compute]
#version 450

// GPU 3D WIND — PASS B: velocity update. A race-free per-cell port of LAMaterialWind3D.step() PASS B.
// Each non-solid cell accelerates its own velocity DOWN the pressure gradient (PASS A's field), adds
// buoyant lift, curls sideways (Coriolis), relaxes toward the prevailing base flow, damps, deflects off
// rock faces, and magnitude-clamps. Reads ONLY pressure + temp + solid + its OWN current velocity and
// writes its OWN velocity, so the update is per-cell with NO neighbour-velocity reads → it updates the
// velocity buffers IN PLACE, exactly like the CPU oracle (each invocation touches only index g). Central
// differences to non-solid neighbours; a solid/out-of-bounds neighbour REFLECTS (its pressure reads as this
// cell's own p0c, so no flow into rock). Constants copied EXACTLY from MaterialWind3D.gd — do not diverge.
//
// Index layout (matches MaterialField3D): idx = (iy*dim_z + iz)*dim_x + ix (X contiguous, then Z, then Y).

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer PressureIn { float pressure[]; };
layout(set = 0, binding = 1, std430) restrict readonly buffer TempIn { float temp[]; };
layout(set = 0, binding = 2, std430) restrict readonly buffer Solid { float solid[]; };
layout(set = 0, binding = 3, std430) restrict buffer VelX { float vel_x[]; };
layout(set = 0, binding = 4, std430) restrict buffer VelY { float vel_y[]; };
layout(set = 0, binding = 5, std430) restrict buffer VelZ { float vel_z[]; };

layout(push_constant, std430) uniform Params {
	uint dim_x;
	uint dim_y;
	uint dim_z;
	uint cell_count;
	float pvx;        // prevailing wind X (world +X)
	float pvz;        // prevailing wind Z (world +Z)
	float dt;         // STEP_DT
	uint buoy;        // 1 = buoyancy enabled (MaterialWind3D._enable_buoyancy)
} params;

// Wind dynamics — MUST match MaterialWind3D.gd exactly.
const float ACCEL = 0.5;            // pressure-gradient -> velocity acceleration gain (× dt)
const float DAMP = 0.08;            // linear drag fraction removed from velocity each step
const float MAX_WIND = 24.0;        // velocity magnitude clamp (stability)
const float BUOY_ACCEL = 0.5;       // upward accel per °C of (this cell − cell above) temperature inversion
const float BUOY_ACCEL_MAX = 6.0;   // cap the buoyant accel before the dt scale (stability)
const float CORIOLIS = 0.6;         // sideways deflection of horizontal wind → pressure lows SPIN
const float EDGE_FORCE = 0.30;      // boundary cells relax this fraction toward the prevailing wind (inflow)
const float BODY_FORCE = 0.02;      // interior cells relax this gentle fraction toward the prevailing wind

void main() {
	uint g = gl_GlobalInvocationID.x;
	if (g >= params.cell_count) {
		return;
	}
	uint dx = params.dim_x;
	uint dy = params.dim_y;
	uint dz = params.dim_z;
	uint layer = dx * dz;
	uint iy = g / layer;
	uint rem = g - iy * layer;
	uint iz = rem / dx;
	uint ix = rem - iz * dx;

	if (solid[g] != 0.0) {
		vel_x[g] = 0.0;
		vel_y[g] = 0.0;
		vel_z[g] = 0.0;
		return;
	}

	float p0c = pressure[g];

	// Central-difference pressure gradient; a solid/out-of-bounds neighbour reflects (reads p0c).
	float px_hi = (ix < dx - 1u && solid[g + 1u] == 0.0) ? pressure[g + 1u] : p0c;
	float px_lo = (ix > 0u && solid[g - 1u] == 0.0) ? pressure[g - 1u] : p0c;
	float pz_hi = (iz < dz - 1u && solid[g + dx] == 0.0) ? pressure[g + dx] : p0c;
	float pz_lo = (iz > 0u && solid[g - dx] == 0.0) ? pressure[g - dx] : p0c;
	float gx = 0.5 * (px_hi - px_lo);
	float gz = 0.5 * (pz_hi - pz_lo);

	float nvx = vel_x[g] - gx * ACCEL * params.dt;
	float nvz = vel_z[g] - gz * ACCEL * params.dt;
	float nvy = vel_y[g];

	// BUOYANCY (vertical wind): a hot cell under a cooler open cell rises. Subsumes VAPOR_RISE.
	if (params.buoy == 1u && iy < dy - 1u) {
		uint iu = g + layer;
		if (solid[iu] == 0.0) {
			float inv = temp[g] - temp[iu];
			if (inv > 0.0) {
				nvy += min(inv * BUOY_ACCEL, BUOY_ACCEL_MAX) * params.dt;
			}
		}
	}

	// CORIOLIS-like deflection: air rushing into a pressure low is curled sideways → a rotating low
	// (vortex) EMERGES. Semi-implicit rotation by the pre-rotation components. Must match MaterialWind3D.gd.
	float rvx = nvx - CORIOLIS * nvz * params.dt;
	float rvz = nvz + CORIOLIS * nvx * params.dt;
	nvx = rvx;
	nvz = rvz;

	// PREVAILING base flow: stronger at the domain boundary (inflow), gentle in the interior.
	bool on_edge = (ix == 0u || ix == dx - 1u || iz == 0u || iz == dz - 1u);
	float force = on_edge ? EDGE_FORCE : BODY_FORCE;
	nvx += (params.pvx - nvx) * force;
	nvz += (params.pvz - nvz) * force;

	// DRAG.
	nvx *= (1.0 - DAMP);
	nvy *= (1.0 - DAMP);
	nvz *= (1.0 - DAMP);

	// TERRAIN DEFLECTION: cannot blow INTO a solid neighbour — zero that component.
	if (nvx > 0.0 && (ix >= dx - 1u || solid[g + 1u] != 0.0)) {
		nvx = 0.0;
	} else if (nvx < 0.0 && (ix == 0u || solid[g - 1u] != 0.0)) {
		nvx = 0.0;
	}
	if (nvz > 0.0 && (iz >= dz - 1u || solid[g + dx] != 0.0)) {
		nvz = 0.0;
	} else if (nvz < 0.0 && (iz == 0u || solid[g - dx] != 0.0)) {
		nvz = 0.0;
	}
	if (nvy > 0.0 && (iy >= dy - 1u || solid[g + layer] != 0.0)) {
		nvy = 0.0;
	} else if (nvy < 0.0 && (iy == 0u || solid[g - layer] != 0.0)) {
		nvy = 0.0;
	}

	// Magnitude clamp (stability).
	float sp2 = nvx * nvx + nvy * nvy + nvz * nvz;
	if (sp2 > MAX_WIND * MAX_WIND) {
		float s = MAX_WIND / sqrt(sp2);
		nvx *= s;
		nvy *= s;
		nvz *= s;
	}

	vel_x[g] = nvx;
	vel_y[g] = nvy;
	vel_z[g] = nvz;
}
