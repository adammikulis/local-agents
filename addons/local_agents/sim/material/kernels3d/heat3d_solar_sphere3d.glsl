#[compute]
#version 450

#include "neighbours.glsli"

// One thread per radial COLUMN. Band-resolved two-stream radiative transfer: the solar beam down, the
// surface, the longwave back up. Optical depth is a sum over absorbers, each scaled by the pressure that
// broadens it.

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict buffer Temp { float temp[]; };
layout(set = 0, binding = 1, std430) restrict readonly buffer Solid { float solid[]; };
layout(set = 0, binding = 4, std430) restrict readonly buffer Snow { float snow[]; };
layout(set = 0, binding = 5, std430) restrict readonly buffer Water { float water[]; };
layout(set = 0, binding = 6, std430) restrict readonly buffer RockFill { float rock_fill[]; };
layout(set = 0, binding = 7, std430) restrict readonly buffer Pressure { float pressure[]; };  // Pa
layout(set = 0, binding = 14, std430) restrict readonly buffer Radial { float radial[]; };
layout(set = 0, binding = 27, std430) restrict readonly buffer Biomass { float biomass[]; };
layout(set = 0, binding = 20, std430) restrict readonly buffer Lava { float lava[]; };
layout(set = 0, binding = 21, std430) restrict readonly buffer Fuel { float fuel[]; };
layout(set = 0, binding = 23, std430) restrict readonly buffer Detritus { float detritus[]; };
layout(set = 0, binding = 30, std430) restrict readonly buffer Sediment { float sediment[]; };
layout(set = 0, binding = 31, std430) restrict readonly buffer Susp { float susp[]; };
layout(set = 0, binding = 32, std430) restrict readonly buffer Dust { float dust[]; };
layout(set = 0, binding = 33, std430) restrict readonly buffer Carbonate { float carbonate[]; };
layout(set = 0, binding = 34, std430) restrict readonly buffer Silica { float silica[]; };
layout(set = 0, binding = 35, std430) restrict readonly buffer Soil { float soil[]; };
layout(set = 0, binding = 36, std430) restrict readonly buffer Moisture { float moisture[]; };
layout(set = 0, binding = 37, std430) restrict readonly buffer Fungus { float fungus[]; };
layout(set = 0, binding = 38, std430) restrict readonly buffer Porosity { float porosity[]; };
// LAAbsorptionBands.packed(): header, band edges, temperature slices, solar weights, five coefficients
// per (temperature, band), Planck CDF.
layout(set = 0, binding = 47, std430) restrict readonly buffer RadTable { float rad_table[]; };
layout(set = 0, binding = 43, std430) restrict readonly buffer CO2 { float co2[]; };

layout(push_constant, std430) uniform Params {
	uint column_count;
	float dt_s;
	uint depth;
	uint band_count;
	float sun_x;        // world-space vector toward the sun; its LENGTH carries relative insolation
	float sun_y;
	float sun_z;
	float pad0;
} params;

#include "rc_shared.glsli"
#include "shell.glsli"

const float STEFAN = 5.670374419e-8;         // LAPhysical.STEFAN_BOLTZMANN
const float SOLAR_CONSTANT = 1361.0;         // LAPhysical.SOLAR_CONSTANT_W_M2
const float KELVIN = 273.15;                 // LAPhysical.KELVIN_OFFSET
const float METRES_PER_MODEL_UNIT = 168.6;   // LAPhysical.METRES_PER_MODEL_UNIT
const float C2_CM_K = 1.4387768775;          // LAPhysical.PLANCK_C2_CM_K
const float DIFFUSIVITY = 1.66;              // LAPhysical.TWO_STREAM_DIFFUSIVITY
const float KAPPA_REF_PA = 1.0e4;            // LAPhysical.ABSORPTION_REF_PRESSURE_PA
const float RHO_CO2_UNIT = 0.3756076619;     // LAPhysical.CO2_UNIT_DENSITY_KG_M3
const float R_CO2 = 188.924269;              // LAPhysical.CO2_GAS_CONST_J_KGK
const float RHO_WATER = 997.0;               // LAPhysical.WATER_DENSITY_KG_M3
const float R_VAPOUR = 461.52;               // LAPhysical.VAPOUR_GAS_CONST_J_KGK
const float AIR_MASS_HORIZON = 38.0;         // LAPhysical.AIR_MASS_HORIZON
const float ALBEDO_GROUND = 0.15;            // LAPhysical.ALBEDO_BARE_GROUND
const float ALBEDO_WATER = 0.06;             // LAPhysical.ALBEDO_OCEAN
const float ALBEDO_ICE = 0.65;               // LAPhysical.ALBEDO_SNOW_ICE
const float ALBEDO_VEG = 0.12;               // LAPhysical.ALBEDO_VEGETATION
const float EMIS_WATER = 0.96;               // LAPhysical.EMISSIVITY_WATER
const float EMIS_SNOW = 0.99;                // LAPhysical.EMISSIVITY_SNOW
const float EMIS_ROCK = 0.95;                // LAPhysical.BASALT_EMISSIVITY
const float RHO_CELLULOSE = 500.0;           // LAPhysical.DRY_WOOD_DENSITY_KG_M3
const float FOLIAGE_FRACTION = 0.03;         // LAPhysical.FOLIAGE_FRACTION_OF_PLANT_MASS
const float LEAF_MASS_PER_AREA = 0.080;      // LAPhysical.LEAF_MASS_PER_AREA_KG_M2
const float CANOPY_EXTINCTION = 0.5;         // LAPhysical.CANOPY_EXTINCTION_COEFF
const float ICE_ALBEDO_GAIN = 40.0;          // snow mass -> reflectivity
const float SURFACE_FILL_MIN = 0.5;          // condensed fraction at which a cell is the surface, not air
const int MAX_LAYERS = 24;                   // atmosphere layers one column may carry

// --- LAAbsorptionBands.packed() accessors ------------------------------------------------------------
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

void main() {
	uint s = gl_GlobalInvocationID.x;
	if (s >= params.column_count) {
		return;
	}
	uint depth = params.depth;
	uint base = s * depth;

	// The surface is the outermost cell of the column that is not free atmosphere: bedrock, a sea top, or
	// the top of a lava flow. One rule, so a stack of anything condensed radiates from its top face only.
	int sfc = -1;
	for (int r = int(depth) - 1; r >= 0; --r) {
		uint c = base + uint(r);
		if (solid[c] != 0.0 || (1.0 - f_air_of(c)) >= SURFACE_FILL_MIN) {
			sfc = r;
			break;
		}
	}
	if (sfc < 0) {
		return;
	}
	uint sc = base + uint(sfc);
	int nlay = min(int(depth) - 1 - sfc, MAX_LAYERS);

	// Per layer: the four pressure-weighted mass paths, the temperature slice, and the running net flux.
	float a_co2[MAX_LAYERS];   // total pressure  x CO2 path   (lines + air-induced continuum)
	float a_cia[MAX_LAYERS];   // CO2 pressure    x CO2 path   (CO2-CO2 collision-induced)
	float a_h2o[MAX_LAYERS];   // total pressure  x H2O path   (lines)
	float a_hc[MAX_LAYERS];    // H2O pressure    x H2O path   (self continuum)
	float tk[MAX_LAYERS];
	float tfrac[MAX_LAYERS];
	uint tslice[MAX_LAYERS];
	float net[MAX_LAYERS];
	float tr[MAX_LAYERS];
	float bl[MAX_LAYERS];
	for (int j = 0; j < nlay; ++j) {
		uint r = uint(sfc + 1 + j);
		uint c = base + r;
		float dz = shell_dr(r) * METRES_PER_MODEL_UNIT;
		float t = max(temp[c] + KELVIN, 1.0);
		tk[j] = t;
		float f = 0.0;
		tslice[j] = slice_of(t, f);
		tfrac[j] = f;
		float rho_v = max(moisture[c], 0.0) * RHO_WATER;
		float rho_c = max(co2[c], 0.0) * RHO_CO2_UNIT;
		float u_co2 = rho_c * dz;
		float u_h2o = rho_v * dz;
		float p_tot = max(pressure[c], 0.0) / KAPPA_REF_PA;
		a_co2[j] = p_tot * u_co2;
		a_cia[j] = (rho_c * R_CO2 * t / KAPPA_REF_PA) * u_co2;
		a_h2o[j] = p_tot * u_h2o;
		a_hc[j] = (rho_v * R_VAPOUR * t / KAPPA_REF_PA) * u_h2o;
		net[j] = 0.0;
	}

	float tks = max(temp[sc] + KELVIN, 1.0);
	float t4s = tks * tks * tks * tks;
	float wet = clamp(water[sc], 0.0, 1.0);
	float icy = clamp(snow[sc] * ICE_ALBEDO_GAIN, 0.0, 1.0);
	float leaf_kg_m2 = max(biomass[sc], 0.0) * RHO_CELLULOSE
		* (shell_dr(uint(sfc)) * METRES_PER_MODEL_UNIT) * FOLIAGE_FRACTION;
	float veg = 1.0 - exp(-CANOPY_EXTINCTION * (leaf_kg_m2 / LEAF_MASS_PER_AREA));
	float land = mix(ALBEDO_GROUND, ALBEDO_VEG, veg);
	float albedo = mix(mix(land, ALBEDO_WATER, wet), ALBEDO_ICE, icy);
	float emis = mix(mix(EMIS_ROCK, EMIS_WATER, wet), EMIS_SNOW, icy);

	uint rb = sc * 3u;
	vec3 sun = vec3(params.sun_x, params.sun_y, params.sun_z);
	float sun_len = length(sun);
	float coz = 0.0;
	if (sun_len > 1.0e-6) {
		coz = dot(vec3(radial[rb + 0u], radial[rb + 1u], radial[rb + 2u]), sun) / sun_len;
	}
	float s_toa = SOLAR_CONSTANT * sun_len * max(coz, 0.0);
	float mu = max(coz, 1.0 / AIR_MASS_HORIZON);

	float net_s = 0.0;
	for (uint b = 0u; b < params.band_count; ++b) {
		float fdn = 0.0;
		for (int j = nlay - 1; j >= 0; --j) {
			uint ti = tslice[j];
			float tf = tfrac[j];
			float dtau = (kappa_at(b, 0u, ti, tf) + kappa_at(b, 1u, ti, tf)) * a_co2[j]
				+ kappa_at(b, 2u, ti, tf) * a_cia[j]
				+ kappa_at(b, 3u, ti, tf) * a_h2o[j]
				+ kappa_at(b, 4u, ti, tf) * a_hc[j];
			float trans = exp(-DIFFUSIVITY * dtau);
			float emit = band_weight(b, tk[j]) * STEFAN * tk[j] * tk[j] * tk[j] * tk[j];
			tr[j] = trans;
			bl[j] = emit;
			float out_f = fdn * trans + (1.0 - trans) * emit;
			net[j] += fdn - out_f;
			fdn = out_f;
		}
		float b_surf = band_weight(b, tks) * STEFAN * t4s;
		net_s += emis * (fdn - b_surf);
		float fup = emis * b_surf + (1.0 - emis) * fdn;
		for (int j = 0; j < nlay; ++j) {
			float out_u = fup * tr[j] + (1.0 - tr[j]) * bl[j];
			net[j] += fup - out_u;
			fup = out_u;
		}

		float w_sun = solar_weight(b);
		if (s_toa <= 0.0 || w_sun <= 0.0) {
			continue;
		}
		// The direct beam takes the slant path; what the ground reflects goes back out diffusely, so it
		// reuses the same transmissivities the longwave sweep already computed.
		float beam = s_toa * w_sun;
		for (int j = nlay - 1; j >= 0; --j) {
			float slant = pow(max(tr[j], 1.0e-30), 1.0 / (DIFFUSIVITY * mu));
			float take = beam * (1.0 - slant);
			net[j] += take;
			beam -= take;
		}
		float refl = beam * albedo;
		net_s += beam - refl;
		for (int j = 0; j < nlay; ++j) {
			float back = refl * (1.0 - tr[j]);
			net[j] += back;
			refl -= back;
		}
	}

	for (int j = 0; j < nlay; ++j) {
		uint r = uint(sfc + 1 + j);
		uint c = base + r;
		float cap = max(rc_of(c) * shell_dr(r) * METRES_PER_MODEL_UNIT, 1.0);
		temp[c] += net[j] * params.dt_s / cap;
	}
	float cap_s = max(rc_of(sc) * shell_dr(uint(sfc)) * METRES_PER_MODEL_UNIT, 1.0);
	temp[sc] += net_s * params.dt_s / cap_s;
}
