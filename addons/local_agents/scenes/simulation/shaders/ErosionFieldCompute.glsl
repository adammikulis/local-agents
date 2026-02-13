#[compute]
#version 450

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) readonly buffer Slope { float v[]; } slope;
layout(set = 0, binding = 1, std430) readonly buffer TempBase { float v[]; } temp_base;
layout(set = 0, binding = 2, std430) readonly buffer Rain { float v[]; } rain;
layout(set = 0, binding = 3, std430) readonly buffer Cloud { float v[]; } cloud;
layout(set = 0, binding = 4, std430) readonly buffer Wetness { float v[]; } wetness;
layout(set = 0, binding = 5, std430) readonly buffer FlowNorm { float v[]; } flow_norm;
layout(set = 0, binding = 6, std430) readonly buffer WaterRel { float v[]; } water_rel;
layout(set = 0, binding = 7, std430) readonly buffer Activity { float v[]; } activity;
layout(set = 0, binding = 8, std430) restrict buffer ErosionBudget { float v[]; } erosion_budget;
layout(set = 0, binding = 9, std430) restrict buffer FrostDamage { float v[]; } frost_damage;
layout(set = 0, binding = 10, std430) restrict buffer TempPrev { float v[]; } temp_prev;
layout(set = 0, binding = 11, std430) restrict buffer ElevDrop { float v[]; } elev_drop;
layout(set = 0, binding = 12, std430) readonly buffer Params {
	float tick;
	float dt;
	float freeze_thresh;
	float seed_jitter;
	float idle_cadence;
} params;

void main() {
	uint idx = gl_GlobalInvocationID.x;
	if (idx >= erosion_budget.v.length()) {
		return;
	}
	float sl = clamp(slope.v[idx], 0.0, 1.0);
	float r = clamp(rain.v[idx], 0.0, 1.0);
	float c = clamp(cloud.v[idx], 0.0, 1.0);
	float w = clamp(wetness.v[idx], 0.0, 1.0);
	float f = clamp(flow_norm.v[idx], 0.0, 1.0);
	float wr = clamp(water_rel.v[idx], 0.0, 1.0);
	float act = clamp(activity.v[idx], 0.0, 1.0);
	float base_t = clamp(temp_base.v[idx], 0.0, 1.0);
	int idle = max(1, int(round(params.idle_cadence)));
	int cadence = clamp(int(round(mix(float(idle), 1.0, act))), 1, idle);
	int phase = int((uint(idx) * 1103515245u + 12345u + uint(params.seed_jitter * 1000.0)) % uint(max(1, cadence)));
	if (((int(params.tick) + phase) % cadence) != 0) {
		elev_drop.v[idx] = 0.0;
		return;
	}
	float local_dt = clamp(params.dt, 0.1, 2.0) * float(cadence);

	float thermal_phase = params.tick * 0.073 + params.seed_jitter;
	float seasonal_swing = sin(thermal_phase) * 0.065;
	float weather_cooling = r * 0.038 + c * 0.024;
	float t = clamp(base_t + seasonal_swing - weather_cooling, 0.0, 1.0);
	float prev_t = clamp(temp_prev.v[idx], 0.0, 1.0);

	float prev_freezing = prev_t <= params.freeze_thresh ? 1.0 : 0.0;
	float now_freezing = t <= params.freeze_thresh ? 1.0 : 0.0;
	float crossed = abs(prev_freezing - now_freezing);
	float freeze_band = 1.0 - clamp(abs(t - params.freeze_thresh) / 0.22, 0.0, 1.0);
	float freeze_water = clamp(w * 0.56 + wr * 0.44, 0.0, 1.0);
	float crack = clamp(sl * 0.72 + f * 0.28, 0.0, 1.0);
	float impulse = crossed * freeze_band * freeze_water * (0.32 + crack * 0.68);
	float frost = clamp(frost_damage.v[idx] * 0.982 + impulse * 0.12, 0.0, 1.0);
	float base_erosion = max(0.0, (sl * 0.62 + f * 0.38) * r * 0.028 * local_dt);
	float frost_erosion = frost * (0.004 + crack * 0.006) * local_dt;
	float cumulative = erosion_budget.v[idx] + base_erosion + frost_erosion;
	float cycles = floor(cumulative / 0.12);
	float next_budget = cumulative - cycles * 0.12;
	float drop = max(0.0, cycles) * 0.004;

	frost_damage.v[idx] = frost;
	temp_prev.v[idx] = t;
	erosion_budget.v[idx] = next_budget;
	elev_drop.v[idx] = drop;
}
