#[compute]
#version 450

// The one gather: every substance that moves between cells moves through it.
// Two passes over the same dispatch. Pass 0 writes what leaves each face into send/send_h; pass 1 gathers.
// Opposite of slot d is d ^ 1.

#include "neighbours.glsli"
#include "generated.glsli"

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict buffer Amount   { float amount[]; };
layout(set = 0, binding = 1, std430) restrict buffer Enthalpy { float h[]; };
layout(set = 0, binding = 2, std430) restrict readonly buffer Neigh { int nbr[]; };
layout(set = 0, binding = 3, std430) restrict readonly buffer Solid { float solid[]; };
// Solved gravity per cell, flat cell*3, m/s^2.
layout(set = 0, binding = 4, std430) restrict readonly buffer Grav { float g_field[]; };

layout(set = 0, binding = 5, std430) restrict readonly buffer VelX { float vel_x[]; };
layout(set = 0, binding = 6, std430) restrict readonly buffer VelY { float vel_y[]; };
layout(set = 0, binding = 7, std430) restrict readonly buffer VelZ { float vel_z[]; };
// Per-face scratch, cell*6 + slot.
layout(set = 0, binding = 8, std430) restrict buffer Send   { float send[]; };
layout(set = 0, binding = 9, std430) restrict buffer SendH  { float send_h[]; };
// Charge rides the mass, exactly as enthalpy does: it is carried, never created by a move.
layout(set = 0, binding = 13, std430) restrict buffer Charge { float charge[]; };
layout(set = 0, binding = 14, std430) restrict buffer SendQ  { float send_q[]; };
// Flow resistance 0..1 per cell.
layout(set = 0, binding = 10, std430) restrict readonly buffer Resist { float resist[]; };
// What the flux runs down. Bound to `amount` when a record has no separate potential.
layout(set = 0, binding = 11, std430) restrict readonly buffer Drive { float drive[]; };
// Whatever else the row's law reads per cell: conductivity for MODE_CONDUCT, cloud water for LAW_OHMIC.
layout(set = 0, binding = 12, std430) restrict readonly buffer Aux { float aux[]; };

layout(set = 0, binding = 15, std430) restrict readonly buffer TempBuf     { float temp[]; };
layout(set = 0, binding = 16, std430) restrict readonly buffer PressureBuf { float pressure[]; };
layout(set = 0, binding = 17, std430) restrict readonly buffer PorosityBuf { float porosity[]; };
layout(set = 0, binding = 18, std430) restrict readonly buffer GrainBuf    { float grain[]; };
layout(set = 0, binding = 19, std430) restrict readonly buffer CO2Buf      { float co2[]; };
// ONE H2O CHANNEL plus the three DERIVED shares state_derive.glsl publishes. Ice, liquid and vapour differ
// optically by more than an order of magnitude, so every radiative term below splits h2o by these.
layout(set = 0, binding = 20, std430) restrict readonly buffer H2OBuf       { float h2o[]; };
// LAAbsorptionBands.packed(): header, band edges, temperature slices, solar weights, five coefficients
// per (temperature, band), Planck CDF.
layout(set = 0, binding = 21, std430) restrict readonly buffer RadTable { float rad_table[]; };
layout(set = 0, binding = 22, std430) restrict readonly buffer H2OSolidBuf  { float h2o_solid[]; };
layout(set = 0, binding = 23, std430) restrict readonly buffer H2OLiquidBuf { float h2o_liquid[]; };
layout(set = 0, binding = 24, std430) restrict readonly buffer SilicateBuf { float silicate[]; };
layout(set = 0, binding = 25, std430) restrict readonly buffer BiomassBuf  { float biomass[]; };
layout(set = 0, binding = 26, std430) restrict readonly buffer SilicateMeltBuf { float silicate_melt[]; };
// Where a row that dissipates writes what it dissipated, J/m^3. Bound to `send_q` when it does not.
layout(set = 0, binding = 27, std430) restrict buffer Stamp { float stamp[]; };
layout(set = 0, binding = 28, std430) restrict readonly buffer H2OVapourBuf { float h2o_vapour[]; };
// TF_FRACTION rows move only this share of `amount` — the phase whose law this row is. 0..1.
// No `restrict` on this or the three below: the grain prologue writes the very buffers three silicate rows
// bind here as their `frac`.
layout(set = 0, binding = 29, std430) readonly buffer FracBuf { float frac[]; };
// Consolidated share of the cell's silicate. A TF_DILUTE row rescales it when matter arrives, because what
// arrives is loose and cement is a share of a total that just grew.
layout(set = 0, binding = 30, std430) restrict buffer CementBuf { float cement[]; };
// Where the cell's loose mineral grains are, written by the PASS_GRAIN prologue.
layout(set = 0, binding = 31, std430) writeonly buffer SuspWater { float silicate_susp_water[]; };
layout(set = 0, binding = 32, std430) writeonly buffer SuspAir { float silicate_susp_air[]; };
layout(set = 0, binding = 33, std430) writeonly buffer Bed { float silicate_bed[]; };
// A TF_LISTED row runs over CellListPass's compacted cell list instead of the grid. Slot 3 of the args is
// the list length; the flag is 1 for every cell in the list.
layout(set = 0, binding = 34, std430) restrict readonly buffer ActiveIdx { uint active_idx[]; };
layout(set = 0, binding = 35, std430) restrict readonly buffer ActiveArgs { uint active_args[]; };
layout(set = 0, binding = 36, std430) restrict readonly buffer ActiveFlag { uint active_flag[]; };
// MODE_RADIATE's own books, J/m^3, assigned in the gather so each is a per-step rate needing no clear.
layout(set = 0, binding = 37, std430) restrict writeonly buffer RadAbs { float rad_absorbed[]; };
layout(set = 0, binding = 38, std430) restrict writeonly buffer RadEmit { float rad_emitted[]; };
// The column field and the breakdown it decides, published rather than re-derived on the CPU.
layout(set = 0, binding = 39, std430) restrict writeonly buffer ColE { float col_e[]; };
layout(set = 0, binding = 40, std430) restrict writeonly buffer Strike { float strike[]; };
// Rock channels two and three, the TF_RADIOGENIC deposit (J/m^3), and the RADIATE march's scratch.
layout(set = 0, binding = 41, std430) restrict readonly buffer CarbonateBuf { float carbonate[]; };
layout(set = 0, binding = 42, std430) restrict readonly buffer SilicaBuf { float silica[]; };
layout(set = 0, binding = 43, std430) restrict writeonly buffer Radiogenic { float radiogenic[]; };
layout(set = 0, binding = 44, std430) restrict buffer LwEmis { float lw_emis[]; };
layout(set = 0, binding = 45, std430) restrict buffer SwAbs { float sw_absorbed[]; };

#include "march.glsli"

layout(push_constant, std430) uniform Params {
	uint cell_count;
	uint pass_id;         // TransportPass.PASS_* — 0 = outflow, 1 = gather, 2 = the grain prologue
	uint mode;            // MODE_* — what drives the flux across a face
	uint law;             // LAW_* — which transport law sets the mobility
	uint band_count;
	uint flags;           // TF_SIGNED | TF_SETTLE | TF_STAMP
	float cell_m;         // cell edge, metres. One number: the grid is uniform.
	float dt_s;
	float repose_tan;     // 0 = a fluid, which levels freely
	float min_amount;     // below this a cell is empty and does not donate
	float density;        // kg/m^3 of the substance this record carries
	float max_fill;       // the amount at which a cell is full
	float lapse_k_per_m;  // MODE_CONVECT: the adiabat this pair must exceed before it overturns
	float fluid_rho;      // kg/m^3 of the fluid the row moves THROUGH
	float fluid_visc;     // Pa s of that fluid
	float grain_d;        // m, the row's own grain diameter where the cell declares none
	float sun_x;          // world-space vector toward the sun; its LENGTH carries relative insolation
	float sun_y;
	float sun_z;
	// PASS_GRAIN weighs a grain against BOTH fluids in one dispatch, so it cannot use fluid_rho/fluid_visc.
	float rho_water;      // LAPhysical.WATER_DENSITY_KG_M3
	float mu_water;       // LAPhysical.WATER_DYNAMIC_VISCOSITY_PA_S
	float rho_air;        // LAPhysical.AIR_DENSITY_KG_M3
	float mu_air;         // LAPhysical.AIR_DYNAMIC_VISCOSITY_PA_S
	// Radiogenic power of one cubic metre of each pure rock at this epoch, W/m^3.
	float w_silicate;
	float w_carbonate;
	float w_silica;
} params;

const uint PASS_GRAIN = 2u;   // TransportPass.PASS_GRAIN

const float KELVIN = 273.15;                        // LAPhysical.KELVIN_OFFSET
const float STEFAN = 5.670374419e-8;                // LAPhysical.STEFAN_BOLTZMANN
const float SOLAR_CONSTANT = 1361.0;                // LAPhysical.SOLAR_CONSTANT_W_M2
const float KOZENY_CARMAN_C = 180.0;                // LAPhysical.KOZENY_CARMAN_C
const float SMAGORINSKY_COEFF = 0.1650789493;             // LAPhysical.SMAGORINSKY_COEFF
const float DRY_AIR_R = 287.0222603;                // LAPhysical.DRY_AIR_GAS_CONSTANT_J_KGK
const float AIR_GAMMA = 1.399764846;                // LAPhysical.AIR_ADIABATIC_INDEX
const float AIR_DENSITY = 1.225;                    // LAPhysical.AIR_DENSITY_KG_M3
const float EPS0 = 8.8541878128e-12;                // LAPhysical.VACUUM_PERMITTIVITY_F_M
const float RREA_THRESHOLD = 2.84e5;                // LAPhysical.RREA_THRESHOLD_V_M
const float CLOUD_COND = 1.0e-14;                   // LAPhysical.CLOUD_CONDUCTIVITY_S_M
const float CLEAR_AIR_COND = 1.0e-13;               // LAPhysical.CLEAR_AIR_CONDUCTIVITY_S_M
const float CHANNEL_COND = 1.0e4;                   // LAPhysical.LIGHTNING_CHANNEL_CONDUCTIVITY_S_M
const float CHARGING_LWC = 1.0e-3;                  // LAPhysical.CHARGING_LWC_KG_M3
const float NIC_CHARGE_RATE = 1.0e-9;               // LAPhysical.NIC_CHARGE_RATE_C_M3_S
const float CHARGE_ZONE_WARM_C = -10.0;             // LAPhysical.CHARGE_ZONE_WARM_C
const float CHARGE_ZONE_COLD_C = -25.0;             // LAPhysical.CHARGE_ZONE_COLD_C
const float CONVECTIVE_UPDRAFT = 10.0;              // LAPhysical.CONVECTIVE_UPDRAFT_M_S
const float BASALT_SOLIDUS_C = 1000.0;              // LAPhysical.BASALT_SOLIDUS_C
const float BASALT_LIQUIDUS_C = 1200.0;             // LAPhysical.BASALT_LIQUIDUS_C
const float MELT_VISC = 100.0;                      // LAPhysical.BASALT_MELT_VISCOSITY_PA_S
const float ROSCOE_N = 2.5;                         // LAPhysical.EINSTEIN_ROSCOE_EXPONENT
const float LOCKUP_CRYSTAL_FRAC = 0.6;              // LAPhysical.RHEOLOGICAL_LOCKUP_CRYSTAL_FRAC
const float DIFFUSIVITY = 1.66;                     // LAPhysical.TWO_STREAM_DIFFUSIVITY
const float C2_CM_K = 1.4387768775;                 // LAPhysical.PLANCK_C2_CM_K
const float KAPPA_REF_PA = 1.0e4;                   // LAPhysical.ABSORPTION_REF_PRESSURE_PA
const float RHO_CO2_UNIT = 0.3898208082;            // LASubstances.co2.density
const float R_CO2 = 188.924269;                     // LAPhysical.CO2_GAS_CONST_J_KGK
const float RHO_WATER = 997.0;                      // LAPhysical.WATER_DENSITY_KG_M3
const float R_VAPOUR = 461.52;                      // LAPhysical.VAPOUR_GAS_CONST_J_KGK
const float ALBEDO_GROUND = 0.15;                   // LAPhysical.ALBEDO_BARE_GROUND
const float ALBEDO_WATER = 0.06;                    // LAPhysical.ALBEDO_OCEAN
const float ALBEDO_ICE = 0.65;                      // LAPhysical.ALBEDO_SNOW_ICE
const float ALBEDO_VEG = 0.12;                      // LAPhysical.ALBEDO_VEGETATION
const float EMIS_WATER = 0.96;                      // LAPhysical.EMISSIVITY_WATER
const float EMIS_SNOW = 0.99;                       // LAPhysical.EMISSIVITY_SNOW
const float EMIS_ROCK = 0.95;                       // LAPhysical.BASALT_EMISSIVITY


vec3 g_at(uint c) {
	return vec3(g_field[c * 3u], g_field[c * 3u + 1u], g_field[c * 3u + 2u]);
}

vec3 vel_at(uint c) {
	return vec3(vel_x[c], vel_y[c], vel_z[c]);
}

// The cell's own grain diameter, or the row's seed where the cell declares none, m.
float grain_d_at(uint c) {
	return grain[c] > 0.0 ? grain[c] : params.grain_d;
}

// Outward unit normal of face d. Slot order -X,+X,-Y,+Y,-Z,+Z.
vec3 face_normal(uint d) {
	float s = (d & 1u) == 1u ? 1.0 : -1.0;
	uint axis = d >> 1u;
	return vec3(axis == 0u ? s : 0.0, axis == 1u ? s : 0.0, axis == 2u ? s : 0.0);
}

float t_k(uint c) {
	return max(temp[c] + KELVIN, 1.0);
}

// Ideal-gas air density from the cell's own pressure and temperature, kg/m^3.
float air_rho(uint c) {
	return max(pressure[c], 0.0) / (DRY_AIR_R * t_k(c));
}

// The cell's h2o split by the shares the enthalpy ladder derived, as volume fractions of the cell.
float h2o_ice(uint c)    { return max(h2o[c], 0.0) * clamp(h2o_solid[c], 0.0, 1.0); }
float h2o_water(uint c)  { return max(h2o[c], 0.0) * clamp(h2o_liquid[c], 0.0, 1.0); }
float h2o_gas(uint c)    { return max(h2o[c], 0.0) * clamp(h2o_vapour[c], 0.0, 1.0); }

// CONDENSED cloud water, droplets and ice alike, kg/m^3: what a rebounding pair is made of and what the
// air's conductivity tracks.
float cloud_water_kg_m3(uint c) {
	return (h2o_water(c) + h2o_ice(c)) * RHO_WATER;
}

// Non-inductive charge separation in the riming band, C/m^3 this step. The light phase carries this much
// charge up and the heavy phase carries the same amount down, so the pair creates nothing.
float separation_dq(uint c, vec3 up) {
	float band = clamp((CHARGE_ZONE_WARM_C - temp[c]) / (CHARGE_ZONE_WARM_C - CHARGE_ZONE_COLD_C),
		0.0, 1.0);
	float wet = clamp(cloud_water_kg_m3(c) / CHARGING_LWC, 0.0, 1.0);
	float lift = clamp(dot(vel_at(c), up) / CONVECTIVE_UPDRAFT, 0.0, 1.0);
	return NIC_CHARGE_RATE * band * wet * lift * params.dt_s;
}

// Volume fraction of the cell that is condensed, so a beam meets it geometrically.
float condensed_frac(uint c) {
	float f = solid[c] != 0.0 ? 1.0 : 0.0;
	f += max(silicate[c], 0.0) + h2o_water(c) + h2o_ice(c);
	return clamp(f, 0.0, 1.0);
}

// --- MOBILITY: one law per row, every term a measured property ---------------------------------------

// Magnitude of the resolved strain-rate tensor, 1/s: |S| = sqrt(2 S_ij S_ij).
float strain_rate(uint c) {
	uint base = c * N_SLOTS;
	mat3 grad = mat3(0.0);
	for (uint a = 0u; a < 3u; ++a) {
		uint slot = a * 2u;
		int lo = nbr[base + slot];
		int hi = nbr[base + opposite_slot(slot)];
		vec3 vlo = lo >= 0 ? vel_at(uint(lo)) : vel_at(c);
		vec3 vhi = hi >= 0 ? vel_at(uint(hi)) : vel_at(c);
		vec3 d = (vhi - vlo) / (2.0 * params.cell_m);
		grad[0][a] = d.x;
		grad[1][a] = d.y;
		grad[2][a] = d.z;
	}
	float s2 = 0.0;
	for (uint i = 0u; i < 3u; ++i) {
		for (uint j = 0u; j < 3u; ++j) {
			float sij = 0.5 * (grad[i][j] + grad[j][i]);
			s2 += 2.0 * sij * sij;
		}
	}
	return sqrt(s2);
}

// Smagorinsky eddy viscosity, m^2/s: nu_t = (C_s dx)^2 |S| plus that fluid's molecular floor.
float eddy_viscosity_of(uint c, float rho, float mu) {
	float mixing = SMAGORINSKY_COEFF * params.cell_m;
	float nu_mol = rho > 0.0 ? mu / rho : 0.0;
	return nu_mol + mixing * mixing * strain_rate(c);
}

float eddy_viscosity(uint c) {
	return eddy_viscosity_of(c, params.fluid_rho, params.fluid_visc);
}

// Einstein-Roscoe: the melt's own viscosity times the crystal framework it is carrying, Pa s. The crystal
// fraction is what the enthalpy ladder derived, not a second reading of the temperature.
float melt_viscosity(uint c) {
	float crystal = 1.0 - clamp(silicate_melt[c], 0.0, 1.0);
	float r = clamp(crystal / LOCKUP_CRYSTAL_FRAC, 0.0, 0.9999);
	return MELT_VISC * pow(1.0 - r, -ROSCOE_N);
}

// Gauss's law along the field line: charge density integrated outward is a surface charge, and a surface
// charge is a field. V/m.
float column_field(uint c) {
	vec3 gv = g_at(c);
	if (length(gv) <= 0.0) {
		return 0.0;
	}
	vec3 up = -normalize(gv);
	float sigma = 0.0;
	uint at = c;
	for (uint i = 0u; i < 64u; ++i) {
		if (solid[at] != 0.0) {
			break;
		}
		sigma += charge[at] * la_step_len(up, params.cell_m);
		int nx = la_step(at, up);
		if (nx < 0) {
			break;
		}
		at = uint(nx);
	}
	return abs(sigma) / EPS0;
}

// Relativistic runaway breakdown field at this cell, V/m: the threshold falls with air density, so it is
// reachable aloft where 3 MV/m conventional breakdown never is. 0 where there is no air to break down.
float rrea_threshold(uint c) {
	if (pressure[c] <= 0.0) {
		return 0.0;
	}
	return RREA_THRESHOLD * air_rho(c) / AIR_DENSITY;
}

// Past the runaway threshold the local air density sets, the dielectric stops being one: the conductivity
// jumps to a return-stroke channel's and the charge row becomes a stroke. `e` is this cell's column field.
float ohmic_conductivity_at(uint c, float e) {
	float ambient = mix(CLEAR_AIR_COND, CLOUD_COND,
		clamp(cloud_water_kg_m3(c) / CHARGING_LWC, 0.0, 1.0));
	float threshold = rrea_threshold(c);
	return (threshold > 0.0 && e >= threshold) ? CHANNEL_COND : ambient;
}

// The fraction of the driving imbalance that crosses a face in one step. Every branch is a transport law
// evaluated on this cell's own state; nothing here is a chosen rate.
float mobility_at(uint c, float amt) {
	float L = params.cell_m;
	float dt = params.dt_s;
	float g = length(g_at(c));
	if (params.law == LAW_SHALLOW) {
		// Inviscid gravity adjustment: du/dt = -g dh/dx, so the head moves at g h dt^2 / L^2. Granular
		// piles take the same law with the repose slope already subtracted (Savage & Hutter 1989).
		return g * (amt * L) * dt * dt / (L * L);
	}
	if (params.law == LAW_FILM) {
		// Nusselt falling film: K = rho g h^2 / (3 mu), and mu climbs as the melt crystallises.
		float hh = amt * L;
		float mu = max(melt_viscosity(c), 1.0e-12);
		return params.density * g * hh * hh * dt / (3.0 * mu * L);
	}
	if (params.law == LAW_DARCY) {
		return 0.0;   // a bond property, not a cell property — see darcy_mobility
	}
	if (params.law == LAW_EDDY) {
		return eddy_viscosity(c) * dt / (L * L);
	}
	if (params.law == LAW_SOUND) {
		return sqrt(AIR_GAMMA * DRY_AIR_R * t_k(c)) * dt / L;
	}
	if (params.law == LAW_OHMIC) {
		// Ohmic relaxation of a space charge: d(rho)/dt = -(sigma/eps0) rho.
		return ohmic_conductivity_at(c, column_field(c)) * dt / EPS0;
	}
	if (params.law == LAW_PGF) {
		// The pressure-gradient force written as a flux: dp * area * dt IS the momentum it delivers.
		return L * L * dt;
	}
	return 0.0;
}

// Hydraulic resistance of half a cell to pore flow, the reciprocal of its Kozeny-Carman permeability.
// An OPEN cell has no matrix and resists nothing; rock with no pore space is impermeable.
float darcy_resistance(uint c) {
	if (solid[c] == 0.0) {
		return 0.0;
	}
	float phi = clamp(porosity[c], 0.0, 0.999);
	if (phi <= 0.0) {
		return 1.0e30;
	}
	float d = grain_d_at(c);
	float k = d * d * phi * phi * phi / (KOZENY_CARMAN_C * max((1.0 - phi) * (1.0 - phi), 1.0e-12));
	return 1.0 / max(k, 1.0e-30);
}

// Two half-cells in series across the bond: K = rho g k_bond / mu, k_bond the series permeability. Two open
// cells resist nothing and pore flow between them is not a thing — their free liquid moves on its own law.
float darcy_mobility(uint a, uint b) {
	float r = 0.5 * (darcy_resistance(a) + darcy_resistance(b));
	if (r <= 0.0) {
		return 0.0;
	}
	return params.fluid_rho * length(g_at(a)) * params.dt_s
		/ (r * max(params.fluid_visc, 1.0e-30) * params.cell_m);
}

// Terminal settling velocity of a grain of diameter `d` in a fluid, m/s (Stokes drag: the buoyant weight
// balanced by 3 pi mu d w).
float stokes_settling(uint c, float d, float rho, float mu) {
	return max(params.density - rho, 0.0) * length(g_at(c)) * d * d / (18.0 * max(mu, 1.0e-30));
}

float settling_speed(uint c) {
	if ((params.flags & TF_SETTLE) == 0u) {
		return 0.0;
	}
	return stokes_settling(c, grain_d_at(c), params.fluid_rho, params.fluid_visc);
}

// Share of grains a fluid holds up. u* = sqrt(nu_t |S|) is the friction velocity, which in a boundary
// layer is the scale of the vertical turbulent fluctuations (Bagnold: suspension once u* > w_s).
float suspended_share(uint c, float rho, float mu) {
	float w_s = stokes_settling(c, grain_d_at(c), rho, mu);
	if (w_s <= 0.0) {
		return 1.0;      // no denser than its fluid, so nothing pulls it out
	}
	return clamp(sqrt(max(eddy_viscosity_of(c, rho, mu) * strain_rate(c), 0.0)) / w_s, 0.0, 1.0);
}

// The velocity the row's matter actually travels at: the fluid's, plus its own fall through it.
vec3 transport_velocity(uint c) {
	vec3 v = vel_at(c);
	vec3 gv = g_at(c);
	if ((params.flags & TF_SETTLE) != 0u && length(gv) > 0.0) {
		v += normalize(gv) * settling_speed(c);
	}
	return v;
}

// --- RADIATION: the band table, read per cell ---------------------------------------------------------

// DECISION, not a law: hops a march may take. SimWorld.grid_res caps at 64, so a ray can cross the box.
const uint MARCH_HOPS = 64u;

uint temp_count() { return uint(rad_table[3]); }
uint edge_off() { return 4u; }
uint temp_off() { return edge_off() + params.band_count + 1u; }
uint wsun_off() { return temp_off() + temp_count(); }
uint kappa_off() { return wsun_off() + params.band_count; }
uint cdf_off() { return kappa_off() + temp_count() * params.band_count * 5u; }
float band_edge(uint b) { return rad_table[edge_off() + b]; }
float solar_weight(uint b) { return rad_table[wsun_off() + b]; }

float kappa_at(uint b, uint k, uint ti, float tf) {
	uint o = kappa_off() + b * 5u + k;
	uint stride = params.band_count * 5u;
	return mix(rad_table[o + ti * stride], rad_table[o + (ti + 1u) * stride], tf);
}

// Temperature slice index and interpolation fraction, held flat outside the tabulated range.
uint slice_of(float tk, out float frac) {
	uint n = temp_count();
	frac = 0.0;
	if (tk <= rad_table[temp_off()]) {
		return 0u;
	}
	if (tk >= rad_table[temp_off() + n - 1u]) {
		return n - 2u;
	}
	uint i = 0u;
	while (i < n - 2u && tk > rad_table[temp_off() + i + 1u]) {
		i += 1u;
	}
	float lo = rad_table[temp_off() + i];
	frac = (tk - lo) / (rad_table[temp_off() + i + 1u] - lo);
	return i;
}

// Fraction of a blackbody's sigma*T^4 emitted above dimensionless frequency x = C2*nu/T.
float planck_above(float x) {
	float xmax = rad_table[2];
	float n = rad_table[1];
	if (x <= 0.0) {
		return 1.0;
	}
	if (x >= xmax) {
		return 0.0;
	}
	float t = x / xmax * (n - 1.0);
	uint i = uint(t);
	return mix(rad_table[cdf_off() + i], rad_table[cdf_off() + i + 1u], t - float(i));
}

// Share of sigma*T^4 in band b. The outermost band keeps everything above its lower edge, so the weights
// sum to 1 and no emission falls off the end of the table.
float band_weight(uint b, float tk) {
	float lo = planck_above(C2_CM_K * band_edge(b) / tk);
	if (b + 1u >= params.band_count) {
		return lo;
	}
	return max(lo - planck_above(C2_CM_K * band_edge(b + 1u) / tk), 0.0);
}

// The four absorber paths this cell presents over `len` metres, kg/m^2 scaled by the broadening pressure:
// CO2 line, CO2 collision-induced, H2O line, H2O self-continuum; line and continuum broaden with p_total.
vec4 absorber_paths(uint c, float len) {
	float tk = t_k(c);
	float rho_v = h2o_gas(c) * RHO_WATER;
	float rho_c = max(co2[c], 0.0) * RHO_CO2_UNIT;
	float p_tot = max(pressure[c], 0.0) / KAPPA_REF_PA;
	return vec4(p_tot * rho_c * len,
		(rho_c * R_CO2 * tk / KAPPA_REF_PA) * rho_c * len,
		p_tot * rho_v * len,
		(rho_v * R_VAPOUR * tk / KAPPA_REF_PA) * rho_v * len);
}

float band_tau(vec4 a, uint b, uint ti, float tf) {
	return (kappa_at(b, 0u, ti, tf) + kappa_at(b, 1u, ti, tf)) * a.x
		+ kappa_at(b, 2u, ti, tf) * a.y
		+ kappa_at(b, 3u, ti, tf) * a.z
		+ kappa_at(b, 4u, ti, tf) * a.w;
}

// The cell's thermal-infrared emissivity: band-resolved optical depth over its own absorber paths,
// Planck-weighted at its own temperature, blended into the emissivity of whatever it holds condensed.
float longwave_emissivity(uint c) {
	float tk = t_k(c);
	vec4 a = absorber_paths(c, params.cell_m);
	float tf = 0.0;
	uint ti = slice_of(tk, tf);
	float eps = 0.0;
	for (uint b = 0u; b < params.band_count; ++b) {
		eps += band_weight(b, tk) * (1.0 - exp(-DIFFUSIVITY * band_tau(a, b, ti, tf)));
	}
	float wet = h2o_water(c);
	float icy = h2o_ice(c);
	float dry = max(silicate[c], 0.0) + (solid[c] != 0.0 ? 1.0 : 0.0);
	float mass = wet + icy + dry;
	if (mass <= 0.0) {
		return clamp(eps, 0.0, 1.0);
	}
	float material = (wet * EMIS_WATER + icy * EMIS_SNOW + dry * EMIS_ROCK) / mass;
	return clamp(mix(eps, material, condensed_frac(c)), 0.0, 1.0);
}

// Shortwave reflectivity: the cited albedo of each thing the cell holds, weighted by how much of it there
// is. A cell holding nothing condensed reflects nothing and the beam goes on through it.
float shortwave_albedo(uint c) {
	float wet = h2o_water(c);
	float icy = h2o_ice(c);
	float veg = max(biomass[c], 0.0);
	float dry = max(silicate[c], 0.0) + (solid[c] != 0.0 ? 1.0 : 0.0);
	float mass = wet + icy + veg + dry;
	if (mass <= 0.0) {
		return 0.0;
	}
	return (wet * ALBEDO_WATER + icy * ALBEDO_ICE + veg * ALBEDO_VEG + dry * ALBEDO_GROUND) / mass;
}

// Share of the DIRECT solar beam a cell takes over `len` m of slant path: the CO2 and H2O bands the
// longwave side reads, weighted by the sun's spectrum. N2 and O2 have no dipole. No diffusivity factor.
float shortwave_absorbed_frac(uint c, float len) {
	vec4 a = absorber_paths(c, len);
	float tf = 0.0;
	uint ti = slice_of(t_k(c), tf);
	float gas = 0.0;
	for (uint b = 0u; b < params.band_count; ++b) {
		gas += solar_weight(b) * (1.0 - exp(-band_tau(a, b, ti, tf)));
	}
	float f_c = condensed_frac(c);
	return clamp(f_c + (1.0 - f_c) * gas, 0.0, 1.0);
}

float solar_step_m() {
	return la_step_len(vec3(params.sun_x, params.sun_y, params.sun_z), params.cell_m);
}

// What reaches this cell of the solar beam, W/m^2, marched along the real slant path to the top of the
// grid. Zero on the night side, where the sun is below this cell's own horizon. Each hop reads a stamp.
float solar_incident(uint c) {
	vec3 sun = vec3(params.sun_x, params.sun_y, params.sun_z);
	float sun_len = length(sun);
	vec3 gv = g_at(c);
	if (sun_len <= 1.0e-6 || length(gv) <= 0.0) {
		return 0.0;
	}
	vec3 dir = sun / sun_len;
	float mu = dot(-normalize(gv), dir);
	if (mu <= 0.0) {
		return 0.0;
	}
	float beam = SOLAR_CONSTANT * sun_len * mu;
	int at = la_step(c, dir);
	for (uint i = 0u; i < MARCH_HOPS && at >= 0 && beam > 0.0; ++i) {
		beam *= 1.0 - sw_absorbed[uint(at)];
		at = la_step(uint(at), dir);
	}
	return beam;
}

// Longwave arriving at `c` through face `d`, J/m^3: every cell on that grid line, attenuated by the cells
// between; what the far end does not take leaves the box for space.
// LA_APPROX: band_averaged_transmittance
float longwave_incident(uint c, uint d) {
	uint back = d ^ 1u;
	float through = 1.0;
	float arriving = 0.0;
	int at = nbr[c * N_SLOTS + d];
	for (uint i = 0u; i < MARCH_HOPS && at >= 0 && through > 0.0; ++i) {
		uint a = uint(at);
		arriving += through * send[a * N_SLOTS + back];
		through *= 1.0 - lw_emis[a];
		at = nbr[a * N_SLOTS + d];
	}
	return arriving;
}

// --- THE GATHER ---------------------------------------------------------------------------------------

// Driving potential across face d, metres of head. A diffusing quantity does not fall, and a row that
// names its own drive already has gravity inside it, so both drop the elevation term.
float potential(uint c, uint d) {
	vec3 gv = g_at(c);
	float gmag = length(gv);
	bool level = params.mode == MODE_DIFFUSE || params.mode == MODE_CONDUCT
		|| params.mode == MODE_RADIATE || (params.flags & TF_DRIVEN) != 0u;
	if (level || gmag <= 0.0) {
		return drive[c] * params.cell_m;
	}
	return drive[c] * params.cell_m + params.cell_m * dot(-gv / gmag, face_normal(d));
}

// PASS_GRAIN: where a cell's loose mineral grains are — carried by water, carried by air, or on the bed.
// The three shares sum to (1 - melt) * (1 - cement), and they are the `frac` of three silicate rows, so
// this runs before any row's pass 0. It reads neighbour velocity, which is why it cannot join the derive.
void grain_state(uint g) {
	float loose = (1.0 - clamp(silicate_melt[g], 0.0, 1.0)) * (1.0 - clamp(cement[g], 0.0, 1.0));
	if (loose <= 0.0) {
		silicate_susp_water[g] = 0.0;
		silicate_susp_air[g] = 0.0;
		silicate_bed[g] = 0.0;
		return;
	}
	float water = h2o_water(g);
	float air = 1.0 - condensed_frac(g);
	float tot = water + air;
	float f_water = tot > 0.0 ? water / tot : 0.0;
	float f_air = tot > 0.0 ? air / tot : 0.0;

	float in_water = f_water * suspended_share(g, params.rho_water, params.mu_water);
	float in_air = f_air * suspended_share(g, params.rho_air, params.mu_air);

	silicate_susp_water[g] = loose * in_water;
	silicate_susp_air[g] = loose * in_air;
	silicate_bed[g] = loose * clamp(1.0 - in_water - in_air, 0.0, 1.0);
}


void main() {
	uint gidx = gl_GlobalInvocationID.x;
	bool listed = (params.flags & TF_LISTED) != 0u;
	if (listed) {
		// The dispatch is indirect over ceil(count/64) groups, so the tail of the last group is past the end.
		if (gidx >= active_args[3]) {
			return;
		}
		gidx = active_idx[gidx];
	}
	if (gidx >= params.cell_count) {
		return;
	}
	if (params.pass_id == PASS_GRAIN) {
		grain_state(gidx);
		return;
	}
	uint base = gidx * N_SLOTS;
	bool is_signed = (params.flags & TF_SIGNED) != 0u;
	// Pore flow's domain IS the rock: its resistance, not a solid mask, is what stops it.
	bool through_pores = params.law == LAW_DARCY;
	// The solid mask stops MATTER. Heat is not matter, so conduction crosses rock both ways.
	bool blocks_solid = !through_pores && params.mode != MODE_RADIATE && params.mode != MODE_CONDUCT;

	if (params.pass_id == 0u) {
		for (uint d = 0u; d < N_SLOTS; ++d) {
			send[base + d] = 0.0;
			send_h[base + d] = 0.0;
			send_q[base + d] = 0.0;
		}
		if (solid[gidx] != 0.0 && blocks_solid) {
			return;
		}
		// MODE_RADIATE emits through every face it has, including the box edge, where nobody gathers it
		// and the emission leaves for space.
		if (params.mode == MODE_RADIATE) {
			float eps = longwave_emissivity(gidx);
			lw_emis[gidx] = eps;
			sw_absorbed[gidx] = shortwave_absorbed_frac(gidx, solar_step_m());
			float tk = t_k(gidx);
			float leaving = eps * STEFAN * tk * tk * tk * tk * params.dt_s / params.cell_m;
			for (uint d = 0u; d < N_SLOTS; ++d) {
				send[base + d] = leaving;
			}
			return;
		}
		// SEPARATION is a transfer between this cell and the one below it, not a flux down a gradient: the
		// donor keeps the light phase's charge and sends the heavy phase's down, so the ledger closes.
		if (params.mode == MODE_SEPARATE) {
			vec3 gv = g_at(gidx);
			if (length(gv) <= 0.0) {
				return;
			}
			vec3 up = -normalize(gv);
			float dq = separation_dq(gidx, up);
			if (dq <= 0.0) {
				return;
			}
			int slot = la_slot_toward(-up);
			if (slot < 0) {
				return;
			}
			int below = nbr[base + uint(slot)];
			// A charge with nowhere to go is not a separated charge.
			if (below < 0 || solid[below] != 0.0) {
				return;
			}
			send[base + uint(slot)] = -dq;
			return;
		}
		// A TF_FRACTION row moves only the phase share `frac` names; the rest of the channel stays put.
		float share = (params.flags & TF_FRACTION) != 0u ? clamp(frac[gidx], 0.0, 1.0) : 1.0;
		float remaining = amount[gidx] * share;
		// No floor on a SIGNED row. Momentum is made by a pressure gradient in a cell that has none, so a
		// donor floor there is a cell that can never start moving.
		if (!is_signed && remaining < params.min_amount) {
			return;
		}
		// Mass carries its heat and its charge. A row that carries no matter carries neither.
		bool carries = params.density > 0.0 && amount[gidx] > 0.0;
		float h_per_unit = carries ? h[gidx] / amount[gidx] : 0.0;
		float q_per_unit = carries ? charge[gidx] / amount[gidx] : 0.0;
		float open = 1.0 - clamp(resist[gidx], 0.0, 1.0);
		if (open <= 0.0) {
			return;
		}
		float mob = mobility_at(gidx, abs(remaining));
		vec3 v_here = transport_velocity(gidx);

		for (uint d = 0u; d < N_SLOTS; ++d) {
			if (!is_signed && remaining < params.min_amount) {
				break;
			}
			int inb = nbr[base + d];
			if (inb < 0) {
				continue;
			}
			if (solid[inb] != 0.0 && blocks_solid) {
				continue;
			}
			uint nb = uint(inb);
			float drop = potential(gidx, d) - potential(nb, d ^ 1u);
			if (!is_signed && drop <= 0.0) {
				continue;
			}
			// A THRESHOLD GRADIENT. Granular material holds a slope up to its angle of repose; a column of
			// gas holds a temperature gradient up to its adiabat. Same construct, one cell of run either way.
			if (params.repose_tan > 0.0) {
				drop -= params.repose_tan * params.cell_m;
				if (drop <= 0.0) {
					continue;
				}
			}
			if (params.mode == MODE_CONVECT) {
				vec3 gv = g_at(gidx);
				float up = dot(-normalize(gv + vec3(1.0e-30)), face_normal(d));
				if (up >= 0.0) {
					continue;   // convection lifts; the sinking half is the neighbour's own pass
				}
				drop -= params.lapse_k_per_m * params.cell_m * (-up);
				if (drop <= 0.0) {
					continue;
				}
			}
			float mob_face = through_pores ? darcy_mobility(gidx, nb) : mob;
			float flow = drop * mob_face * open / params.cell_m;
			if (params.mode == MODE_CONDUCT) {
				// Series half-cells, so the interface conductivity is the harmonic mean, and
				// dh = lambda_i * (T_here - T_nb) * dt / dx^2 off `drive`: `drop` carries a spare cell_m.
				float a = aux[gidx];
				float b = aux[nb];
				float lam = 2.0 * a * b / max(a + b, 1.0e-12);
				flow = lam * (drive[gidx] - drive[nb]) * params.dt_s
					/ (params.cell_m * params.cell_m);
			}

			if (params.mode == MODE_ADVECT || params.mode == MODE_BOTH) {
				// Outgoing advective flux; the neighbour's pass handles the other direction.
				float vn = dot(v_here, face_normal(d));
				if (vn > 0.0) {
					flow += remaining * vn * params.dt_s / params.cell_m;
				} else if (params.mode == MODE_ADVECT) {
					continue;
				}
			}
			if (is_signed) {
				// Momentum is signed and unbounded: a pressure gradient makes it in a cell that has none,
				// so no donor floor and no room limit apply.
				if (flow == 0.0) {
					continue;
				}
				send[base + d] = flow;
				continue;
			}
			float room = max(params.max_fill - amount[nb], 0.0);
			flow = clamp(flow, 0.0, min(remaining, room));
			if (flow <= 0.0) {
				continue;
			}
			send[base + d] = flow;
			send_h[base + d] = flow * h_per_unit;
			send_q[base + d] = flow * q_per_unit;
			remaining -= flow;
		}
		return;
	}

	// Pass 1: gather.
	float gained = 0.0;
	float gained_h = 0.0;
	float gained_q = 0.0;
	float lost = 0.0;
	float lost_h = 0.0;
	float lost_q = 0.0;
	float absorptivity = params.mode == MODE_RADIATE ? lw_emis[gidx] : 0.0;
	for (uint d = 0u; d < N_SLOTS; ++d) {
		lost += send[base + d];
		lost_h += send_h[base + d];
		lost_q += send_q[base + d];
		int inb = nbr[base + d];
		if (inb < 0) {
			continue;
		}
		uint nb = uint(inb);
		// A cell outside the list never ran pass 0 this row, so its face scratch still holds another row's.
		if (listed && active_flag[nb] == 0u) {
			continue;
		}
		// Radiation arrives from the whole grid line behind this face, not just from the cell touching it.
		gained += params.mode == MODE_RADIATE
			? absorptivity * longwave_incident(gidx, d)
			: send[nb * N_SLOTS + (d ^ 1u)];
		gained_h += send_h[nb * N_SLOTS + (d ^ 1u)];
		gained_q += send_q[nb * N_SLOTS + (d ^ 1u)];
	}
	if (params.mode == MODE_RADIATE) {
		float sun_w = solar_incident(gidx);
		float taken = sun_w * sw_absorbed[gidx] * (1.0 - shortwave_albedo(gidx));
		gained += taken * params.dt_s / params.cell_m;
		rad_absorbed[gidx] = gained;
		rad_emitted[gidx] = lost;
	}
	// No floor. Pass 0 clamps every outflow to what the cell holds, so a negative here is a defect
	// and clamping it up would create the mass it is short of.
	float was = amount[gidx];
	amount[gidx] = was - lost + gained;
	// The cemented AMOUNT cannot change by transport — rock does not flow, and what arrives is loose — so
	// the cemented SHARE falls by exactly the ratio the total grew.
	if ((params.flags & TF_DILUTE) != 0u && amount[gidx] > was && was > 0.0) {
		cement[gidx] = clamp(cement[gidx] * was / amount[gidx], 0.0, 1.0);
	}
	h[gidx] = h[gidx] - lost_h + gained_h;
	charge[gidx] = charge[gidx] - lost_q + gained_q;
	if ((params.flags & TF_STAMP) != 0u) {
		// Ohmic dissipation, J/m^3: sigma E^2 is the power the medium takes out of the field it conducts in.
		// ONE march: the column integral is the same one the conductivity and the strike test both read.
		float e_here = column_field(gidx);
		float joule = ohmic_conductivity_at(gidx, e_here) * e_here * e_here * params.dt_s;
		stamp[gidx] += joule;
		h[gidx] += joule;
		// Published where it is DECIDED: col_e is the field in V/m, strike marks where it broke down.
		float thr = rrea_threshold(gidx);
		col_e[gidx] = e_here;
		strike[gidx] = (thr > 0.0 && e_here >= thr) ? 1.0 : 0.0;
	}
	if ((params.flags & TF_RADIOGENIC) != 0u) {
		// The rock warms itself, at this epoch's rate. This row carries h_j_m3, so `amount` IS enthalpy.
		float dq = (max(silicate[gidx], 0.0) * params.w_silicate
			+ max(carbonate[gidx], 0.0) * params.w_carbonate
			+ max(silica[gidx], 0.0) * params.w_silica) * params.dt_s;
		amount[gidx] += dq;
		radiogenic[gidx] = dq;
	}
}
