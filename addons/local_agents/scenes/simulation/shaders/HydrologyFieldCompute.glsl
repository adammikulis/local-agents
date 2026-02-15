#[compute]
#version 450

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) readonly buffer BaseMoisture { float v[]; } base_moisture;
layout(set = 0, binding = 1, std430) readonly buffer BaseElevation { float v[]; } base_elevation;
layout(set = 0, binding = 2, std430) readonly buffer BaseSlope { float v[]; } base_slope;
layout(set = 0, binding = 3, std430) readonly buffer BaseHeat { float v[]; } base_heat;
layout(set = 0, binding = 4, std430) readonly buffer SpringDischarge { float v[]; } spring_discharge;
layout(set = 0, binding = 5, std430) readonly buffer Rain { float v[]; } rain;
layout(set = 0, binding = 6, std430) readonly buffer Wetness { float v[]; } wetness;
layout(set = 0, binding = 7, std430) readonly buffer Activity { float v[]; } activity;
layout(set = 0, binding = 8, std430) buffer Flow { float v[]; } flow;
layout(set = 0, binding = 9, std430) buffer Reliability { float v[]; } reliability;
layout(set = 0, binding = 10, std430) buffer FloodRisk { float v[]; } flood_risk;
layout(set = 0, binding = 11, std430) buffer WaterDepth { float v[]; } water_depth;
layout(set = 0, binding = 12, std430) buffer Pressure { float v[]; } pressure;
layout(set = 0, binding = 13, std430) buffer Recharge { float v[]; } recharge;
layout(set = 0, binding = 14, std430) readonly buffer Params {
	float dt;
	float tick;
	float idle_cadence;
	float phase_seed;
	float tile_count;
} params;

void main() {
	uint idx = gl_GlobalInvocationID.x;
	if (idx >= uint(params.tile_count)) {
		return;
	}
	float act = clamp(activity.v[idx], 0.0, 1.0);
	int idle = max(1, int(round(params.idle_cadence)));
	int cadence = clamp(int(round(mix(float(idle), 1.0, act))), 1, idle);
	int phase = int((uint(idx) * 1664525u + uint(params.phase_seed * 131.0)) % uint(max(1, cadence)));
	if (((int(params.tick) + phase) % cadence) != 0) {
		return;
	}

	float local_dt = max(0.0001, params.dt) * float(cadence);
	float moist = clamp(base_moisture.v[idx], 0.0, 1.0);
	float elev = clamp(base_elevation.v[idx], 0.0, 1.0);
	float slope = clamp(base_slope.v[idx], 0.0, 1.0);
	float heat = clamp(base_heat.v[idx], 0.0, 1.5);
	float spring = clamp(spring_discharge.v[idx], 0.0, 8.0);
	float rain_v = clamp(rain.v[idx], 0.0, 1.0);
	float wet_v = clamp(wetness.v[idx], 0.0, 1.0);

	float prev_flow = max(0.0, flow.v[idx]);
	float prev_rel = clamp(reliability.v[idx], 0.0, 1.0);
	float prev_flood = clamp(flood_risk.v[idx], 0.0, 1.0);
	float prev_depth = clamp(water_depth.v[idx], 0.0, 99.0);
	float prev_pressure = clamp(pressure.v[idx], 0.0, 1.0);
	float prev_recharge = clamp(recharge.v[idx], 0.0, 1.0);

	float runoff = clamp((slope * 0.55 + rain_v * 0.45) * (0.7 + wet_v * 0.3), 0.0, 1.0);
	float infiltration = clamp((0.06 + moist * 0.2 + wet_v * 0.22 + rain_v * 0.1) * (1.0 - slope * 0.45), 0.0, 1.0);
	float evap_loss = clamp(0.01 + heat * 0.05 + (1.0 - moist) * 0.025, 0.0, 0.2);
	float next_recharge = clamp(prev_recharge * 0.92 + infiltration * local_dt - runoff * 0.015 * local_dt - evap_loss * 0.05 * local_dt, 0.0, 1.0);
	float next_pressure = clamp(prev_pressure * 0.9 + next_recharge * 0.1 * local_dt + spring * 0.01 - runoff * 0.03 * local_dt, 0.0, 1.0);
	float target_depth = clamp(8.0 + elev * 10.0 - next_recharge * 7.5 - next_pressure * 4.5 - spring * 0.9 + heat * 1.9, 0.0, 99.0);
	float next_depth = mix(prev_depth, target_depth, clamp(0.12 * local_dt, 0.0, 1.0));
	float groundwater = clamp(1.0 - (next_depth / 12.0), 0.0, 1.0);
	float next_flow = max(0.0, prev_flow * 0.93 + rain_v * 0.45 * local_dt + runoff * 0.38 + groundwater * 0.35 + spring * 0.2);
	float flow_norm = 1.0 - exp(-next_flow * 0.18);
	float next_rel = clamp(flow_norm * 0.48 + groundwater * 0.19 + moist * 0.14 + next_recharge * 0.11 + next_pressure * 0.08, 0.0, 1.0);
	float next_flood = clamp(prev_flood * 0.9 + rain_v * 0.2 + runoff * 0.26 + next_pressure * 0.14 + spring * 0.03, 0.0, 1.0);

	flow.v[idx] = next_flow;
	reliability.v[idx] = next_rel;
	flood_risk.v[idx] = next_flood;
	water_depth.v[idx] = next_depth;
	pressure.v[idx] = next_pressure;
	recharge.v[idx] = next_recharge;
}
