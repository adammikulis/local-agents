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
layout(set = 0, binding = 20, std430) restrict readonly buffer MoistureBuf { float moisture[]; };
// LAAbsorptionBands.packed(): header, band edges, temperature slices, solar weights, five coefficients
// per (temperature, band), Planck CDF.
layout(set = 0, binding = 21, std430) restrict readonly buffer RadTable { float rad_table[]; };
layout(set = 0, binding = 22, std430) restrict readonly buffer SnowBuf     { float snow[]; };
layout(set = 0, binding = 23, std430) restrict readonly buffer WaterBuf    { float water[]; };
layout(set = 0, binding = 24, std430) restrict readonly buffer RockFillBuf { float rock_fill[]; };
layout(set = 0, binding = 25, std430) restrict readonly buffer BiomassBuf  { float biomass[]; };
layout(set = 0, binding = 26, std430) restrict readonly buffer LavaBuf     { float lava[]; };
// Where a row that dissipates writes what it dissipated, J/m^3. Bound to `send_q` when it does not.
layout(set = 0, binding = 27, std430) restrict buffer Stamp { float stamp[]; };

#include "march.glsli"

layout(push_constant, std430) uniform Params {
	uint cell_count;
	uint pass_id;         // 0 = outflow, 1 = gather
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
} params;

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
const float BASALT_SOLIDUS_C = 1000.0;              // LAPhysical.BASALT_SOLIDUS_C
const float BASALT_LIQUIDUS_C = 1200.0;             // LAPhysical.BASALT_LIQUIDUS_C
const float MELT_VISC = 100.0;                      // LAPhysical.BASALT_MELT_VISCOSITY_PA_S
const float ROSCOE_N = 2.5;                         // LAPhysical.EINSTEIN_ROSCOE_EXPONENT
const float LOCKUP_CRYSTAL_FRAC = 0.6;              // LAPhysical.RHEOLOGICAL_LOCKUP_CRYSTAL_FRAC
const float SW_OPTICAL_DEPTH = 0.2597;              // LAPhysical.ATMOS_SW_OPTICAL_DEPTH
const float P_STD = 101325.0;                       // LAPhysical.STANDARD_PRESSURE_PA
const float DIFFUSIVITY = 1.66;                     // LAPhysical.TWO_STREAM_DIFFUSIVITY
const float C2_CM_K = 1.4387768775;                 // LAPhysical.PLANCK_C2_CM_K
const float KAPPA_REF_PA = 1.0e4;                   // LAPhysical.ABSORPTION_REF_PRESSURE_PA
const float RHO_CO2_UNIT = 0.3898208082;            // LAPhysical.CO2_UNIT_DENSITY_KG_M3
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

// Volume fraction of the cell that is condensed, so a beam meets it geometrically.
float condensed_frac(uint c) {
	float f = solid[c] != 0.0 ? 1.0 : 0.0;
	f += max(rock_fill[c], 0.0) + max(water[c], 0.0) + max(snow[c], 0.0) + max(lava[c], 0.0);
	return clamp(f, 0.0, 1.0);
}

// --- MOBILITY: one law per row, every term a measured property ---------------------------------------

// Resolved-strain eddy viscosity, m^2/s: Smagorinsky nu_t = (C_s * dx)^2 * |S| plus the molecular floor.
float eddy_viscosity(uint c) {
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
	float mixing = SMAGORINSKY_COEFF * params.cell_m;
	float nu_mol = params.fluid_rho > 0.0 ? params.fluid_visc / params.fluid_rho : 0.0;
	return nu_mol + mixing * mixing * sqrt(s2);
}

// Einstein-Roscoe: the melt's own viscosity times the crystal framework it is carrying, Pa s. The crystal
// fraction is where the cell sits between the solidus and the liquidus.
float melt_viscosity(uint c) {
	float f_melt = clamp((temp[c] - BASALT_SOLIDUS_C) / (BASALT_LIQUIDUS_C - BASALT_SOLIDUS_C), 0.0, 1.0);
	float crystal = 1.0 - f_melt;
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

// Past the runaway threshold the local air density sets, the dielectric stops being one: the conductivity
// jumps to a return-stroke channel's and the charge row becomes a stroke.
float ohmic_conductivity(uint c) {
	float lwc = max(aux[c], 0.0) * RHO_WATER;
	float ambient = mix(CLEAR_AIR_COND, CLOUD_COND, clamp(lwc / CHARGING_LWC, 0.0, 1.0));
	if (pressure[c] <= 0.0) {
		return ambient;
	}
	float threshold = RREA_THRESHOLD * air_rho(c) / AIR_DENSITY;
	return (threshold > 0.0 && column_field(c) >= threshold) ? CHANNEL_COND : ambient;
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
		// Kozeny-Carman permeability of the cell's own pore geometry, then K = rho g k / mu.
		float phi = clamp(porosity[c], 0.0, 0.999);
		float d = grain[c] > 0.0 ? grain[c] : params.grain_d;
		float open_frac = (1.0 - phi) * (1.0 - phi);
		float k = d * d * phi * phi * phi / (KOZENY_CARMAN_C * max(open_frac, 1.0e-12));
		return params.fluid_rho * g * k * dt / (max(params.fluid_visc, 1.0e-30) * L);
	}
	if (params.law == LAW_EDDY) {
		return eddy_viscosity(c) * dt / (L * L);
	}
	if (params.law == LAW_SOUND) {
		return sqrt(AIR_GAMMA * DRY_AIR_R * t_k(c)) * dt / L;
	}
	if (params.law == LAW_OHMIC) {
		// Ohmic relaxation of a space charge: d(rho)/dt = -(sigma/eps0) rho.
		return ohmic_conductivity(c) * dt / EPS0;
	}
	if (params.law == LAW_PGF) {
		// The pressure-gradient force written as a flux: dp * area * dt IS the momentum it delivers.
		return L * L * dt;
	}
	return 0.0;
}

// Terminal settling velocity of the row's grain in the row's fluid, m/s (Stokes drag).
float settling_speed(uint c) {
	if ((params.flags & TF_SETTLE) == 0u) {
		return 0.0;
	}
	float d = params.grain_d;
	float mu = max(params.fluid_visc, 1.0e-30);
	return max(params.density - params.fluid_rho, 0.0) * length(g_at(c)) * d * d / (18.0 * mu);
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

uint temp_count() { return uint(rad_table[3]); }
uint edge_off() { return 4u; }
uint temp_off() { return edge_off() + params.band_count + 1u; }
uint wsun_off() { return temp_off() + temp_count(); }
uint kappa_off() { return wsun_off() + params.band_count; }
uint cdf_off() { return kappa_off() + temp_count() * params.band_count * 5u; }
float band_edge(uint b) { return rad_table[edge_off() + b]; }

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

// The cell's thermal-infrared emissivity: band-resolved optical depth over its own absorber paths,
// Planck-weighted at its own temperature, blended into the emissivity of whatever it holds condensed.
float longwave_emissivity(uint c) {
	float tk = t_k(c);
	float dz = params.cell_m;
	float rho_v = max(moisture[c], 0.0) * RHO_WATER;
	float rho_c = max(co2[c], 0.0) * RHO_CO2_UNIT;
	float p_tot = max(pressure[c], 0.0) / KAPPA_REF_PA;
	float a_co2 = p_tot * rho_c * dz;
	float a_cia = (rho_c * R_CO2 * tk / KAPPA_REF_PA) * rho_c * dz;
	float a_h2o = p_tot * rho_v * dz;
	float a_hc = (rho_v * R_VAPOUR * tk / KAPPA_REF_PA) * rho_v * dz;
	float tf = 0.0;
	uint ti = slice_of(tk, tf);
	float eps = 0.0;
	for (uint b = 0u; b < params.band_count; ++b) {
		float dtau = (kappa_at(b, 0u, ti, tf) + kappa_at(b, 1u, ti, tf)) * a_co2
			+ kappa_at(b, 2u, ti, tf) * a_cia
			+ kappa_at(b, 3u, ti, tf) * a_h2o
			+ kappa_at(b, 4u, ti, tf) * a_hc;
		eps += band_weight(b, tk) * (1.0 - exp(-DIFFUSIVITY * dtau));
	}
	float wet = max(water[c], 0.0);
	float icy = max(snow[c], 0.0);
	float dry = max(rock_fill[c], 0.0) + max(lava[c], 0.0) + (solid[c] != 0.0 ? 1.0 : 0.0);
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
	float wet = max(water[c], 0.0);
	float icy = max(snow[c], 0.0);
	float veg = max(biomass[c], 0.0);
	float dry = max(rock_fill[c], 0.0) + max(lava[c], 0.0) + (solid[c] != 0.0 ? 1.0 : 0.0);
	float mass = wet + icy + veg + dry;
	if (mass <= 0.0) {
		return 0.0;
	}
	return (wet * ALBEDO_WATER + icy * ALBEDO_ICE + veg * ALBEDO_VEG + dry * ALBEDO_GROUND) / mass;
}

// Shortwave optical depth of one cell over path `len`. Beer-Lambert over the air it holds, plus the
// condensed fraction, which the beam meets geometrically rather than spectrally.
float shortwave_absorbed_frac(uint c, float len) {
	float column = air_rho(c) * len * length(g_at(c)) / P_STD;
	float gas = 1.0 - exp(-SW_OPTICAL_DEPTH * max(column, 0.0));
	float f_c = condensed_frac(c);
	return clamp(f_c + (1.0 - f_c) * gas, 0.0, 1.0);
}

// What reaches this cell of the solar beam, W/m^2, marched along the real slant path to the top of the
// grid. Zero on the night side, where the sun is below this cell's own horizon.
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
	float step_m = la_step_len(dir, params.cell_m);
	for (uint i = 0u; i < 64u && at >= 0 && beam > 0.0; ++i) {
		beam *= 1.0 - shortwave_absorbed_frac(uint(at), step_m);
		at = la_step(uint(at), dir);
	}
	return beam;
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

void main() {
	uint gidx = gl_GlobalInvocationID.x;
	if (gidx >= params.cell_count) {
		return;
	}
	uint base = gidx * N_SLOTS;
	bool is_signed = (params.flags & TF_SIGNED) != 0u;

	if (params.pass_id == 0u) {
		for (uint d = 0u; d < N_SLOTS; ++d) {
			send[base + d] = 0.0;
			send_h[base + d] = 0.0;
			send_q[base + d] = 0.0;
		}
		if (solid[gidx] != 0.0 && params.mode != MODE_RADIATE) {
			return;
		}
		// MODE_RADIATE emits through every face it has, including the box edge, where nobody gathers it
		// and the emission leaves for space.
		if (params.mode == MODE_RADIATE) {
			float tk = t_k(gidx);
			float leaving = longwave_emissivity(gidx) * STEFAN * tk * tk * tk * tk
				* params.dt_s / params.cell_m;
			for (uint d = 0u; d < N_SLOTS; ++d) {
				send[base + d] = leaving;
			}
			return;
		}
		float remaining = amount[gidx];
		if (!is_signed && remaining < params.min_amount) {
			return;
		}
		if (is_signed && abs(remaining) < params.min_amount) {
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
			if (inb < 0 || solid[inb] != 0.0) {
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
			float flow = drop * mob * open / params.cell_m;
			if (params.mode == MODE_CONDUCT) {
				// Two half-cells in series across the bond, so the interface conductivity is the harmonic
				// mean. dh = lambda_i * (T_nb - T_here) * dt / dx^2, with no capacity: h IS the state.
				float a = aux[gidx];
				float b = aux[nb];
				float lam = 2.0 * a * b / max(a + b, 1.0e-12);
				flow = drop * lam * params.dt_s / (params.cell_m * params.cell_m);
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
	float absorptivity = params.mode == MODE_RADIATE ? longwave_emissivity(gidx) : 0.0;
	for (uint d = 0u; d < N_SLOTS; ++d) {
		lost += send[base + d];
		lost_h += send_h[base + d];
		lost_q += send_q[base + d];
		int inb = nbr[base + d];
		if (inb < 0) {
			continue;
		}
		uint nb = uint(inb);
		float in_amt = send[nb * N_SLOTS + (d ^ 1u)];
		// What a neighbour radiated is absorbed only in proportion to this cell's own absorptivity; the
		// rest passes on out of the world, which is how a transparent atmosphere lets the ground cool.
		gained += params.mode == MODE_RADIATE ? in_amt * absorptivity : in_amt;
		gained_h += send_h[nb * N_SLOTS + (d ^ 1u)];
		gained_q += send_q[nb * N_SLOTS + (d ^ 1u)];
	}
	if (params.mode == MODE_RADIATE) {
		float sun_w = solar_incident(gidx);
		float taken = sun_w * shortwave_absorbed_frac(gidx, params.cell_m)
			* (1.0 - shortwave_albedo(gidx));
		gained += taken * params.dt_s / params.cell_m;
	}
	// No floor. Pass 0 clamps every outflow to what the cell holds, so a negative here is a defect
	// and clamping it up would create the mass it is short of.
	amount[gidx] = amount[gidx] - lost + gained;
	h[gidx] = h[gidx] - lost_h + gained_h;
	charge[gidx] = charge[gidx] - lost_q + gained_q;
	if ((params.flags & TF_STAMP) != 0u) {
		// Ohmic dissipation, J/m^3: sigma E^2 is the power the medium takes out of the field it conducts in.
		float e_here = column_field(gidx);
		float joule = ohmic_conductivity(gidx) * e_here * e_here * params.dt_s;
		stamp[gidx] += joule;
		h[gidx] += joule;
	}
}
