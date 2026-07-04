#[compute]
#version 450

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) readonly buffer PositionIn { vec4 data[]; } positions_in;
layout(set = 0, binding = 1, std430) readonly buffer VelocityIn { vec4 data[]; } velocities_in;
layout(set = 0, binding = 2, std430) restrict buffer PositionOut { vec4 data[]; } positions_out;
layout(set = 0, binding = 3, std430) restrict buffer VelocityOut { vec4 data[]; } velocities_out;
layout(set = 0, binding = 4, std430) readonly buffer TargetIntent { vec4 data[]; } target_intent;
layout(set = 0, binding = 5, std430) readonly buffer AvoidanceIntent { vec4 data[]; } avoidance_intent;
layout(set = 0, binding = 6, std430) readonly buffer Params {
	float dt;
	float separation_weight;
	float alignment_weight;
	float cohesion_weight;
	float target_weight;
	float avoidance_weight;
	float neighbor_radius;
	float separation_radius;
	float max_speed;
	float max_force;
	float world_bounds_radius;
	float agent_count;
	float neighbor_radius_sq;
	float separation_radius_sq;
	float world_surface_has_height;
	float world_surface_width;
	float world_surface_depth;
	float voxel_avoid_distance;
	float world_avoid_weight;
	float agent_radius;
	float ground_clearance;
	float fly_clearance;
	float max_terrain_step;
	float max_altitude;
	float seek_high_ground;
	float orbit_radius;
	float orbit_rate;
	float altitude_seek_weight;
	float altitude_seek_target;
	float flock_center_x;
	float flock_center_y;
	float flock_center_z;
	float flock_velocity_x;
	float flock_velocity_y;
	float flock_velocity_z;
	float max_fly_climb_speed;
	float max_fly_sink_speed;
} params;
layout(set = 0, binding = 7, std430) readonly buffer WorldSurfaceHeight { int data[]; } world_surface_height;

vec3 safe_normalize(vec3 value) {
	float m = length(value);
	if (m <= 0.000001) {
		return vec3(0.0);
	}
	return value / m;
}

float safe_inverse(float value) {
	float abs_value = abs(value);
	return abs_value > 0.000001 ? (1.0 / abs_value) : 0.0;
}

vec3 clamp_length(vec3 value, float limit) {
	float m = length(value);
	if (m <= limit || limit <= 0.0) {
		return value;
	}
	return value * (limit / m);
}

bool is_finite_vec3(vec3 value) {
	return all(isfinite(value));
}

vec3 fallback_if_non_finite(vec3 value, vec3 fallback) {
	return is_finite_vec3(value) ? value : fallback;
}

float sample_world_surface_height(vec3 sample_position) {
	if (params.world_surface_has_height <= 0.5) {
		return 0.0;
	}
	if (params.world_surface_width <= 0.0 || params.world_surface_depth <= 0.0) {
		return 0.0;
	}
	float safe_x = clamp(sample_position.x, 0.0, params.world_surface_width - 1.0);
	float safe_z = clamp(sample_position.z, 0.0, params.world_surface_depth - 1.0);
	int x = int(floor(safe_x));
	int z = int(floor(safe_z));
	int idx = z * int(params.world_surface_width) + x;
	int max_idx = int(params.world_surface_width * params.world_surface_depth);
	if (idx < 0 || idx >= max_idx) {
		return 0.0;
	}
	return float(world_surface_height.data[idx]);
}

vec3 world_avoidance(vec3 position, vec3 velocity) {
	if (params.world_avoid_weight <= 0.0001 || params.world_surface_has_height <= 0.5) {
		return vec3(0.0);
	}

	float clearance_floor = max(max(params.ground_clearance, params.fly_clearance), 0.0001);
	float effective_clearance = params.seek_high_ground > 0.5 ? max(clearance_floor, params.ground_clearance) : clearance_floor;
	effective_clearance = max(effective_clearance, 0.0001);
	float probe_radius = max(params.voxel_avoid_distance, max(params.agent_radius * 2.0, 0.001));
	float terrain_here = sample_world_surface_height(position);
	float clearance_here = position.y - terrain_here;
	vec3 avoid = vec3(0.0);
	float clearance_pressure = clamp((clearance_floor - clearance_here) * safe_inverse(clearance_floor), 0.0, 1.0);
	float dive_pressure = clamp((-velocity.y) * safe_inverse(clearance_floor), 0.0, 1.0);
	float air_pressure = clamp(0.5 + 0.5 * clearance_pressure, 0.0, 1.0);
	float climb_cap = max(max(params.max_fly_climb_speed, 0.0), 0.02);

	if (clearance_here < effective_clearance) {
		float below_ratio = clamp((effective_clearance - clearance_here) * safe_inverse(effective_clearance), 0.0, 1.0);
		float settle_ratio = mix(0.2, 1.0, below_ratio);
		float climb_scale = mix(0.0, climb_cap * 1.8, settle_ratio);
		climb_scale += climb_cap * air_pressure * dive_pressure * 0.75;
		avoid += vec3(0.0, climb_scale, 0.0);
	}

	float has_velocity = length(velocity);
	vec3 forward = has_velocity > 0.0001 ? velocity / has_velocity : vec3(0.0, 0.0, 1.0);
	float stride_probe = sample_world_surface_height(position + forward * probe_radius) - terrain_here;
	float stride_limit = max(params.max_terrain_step, 0.0001);
	if (stride_probe > stride_limit) {
		float stride_ratio = clamp((stride_probe - stride_limit) * safe_inverse(max(stride_limit, 1.0)), 0.0, 1.0);
		avoid += -safe_normalize(vec3(forward.x, 0.0, forward.z)) * stride_ratio;
	}

	for (int i = 0; i < 8; i++) {
		float a = float(i) * 0.78539816339;
		vec2 sample_dir = vec2(cos(a), sin(a));
		vec3 sample_position = position + vec3(sample_dir.x, 0.0, sample_dir.y) * probe_radius;
		float terrain = sample_world_surface_height(sample_position);
		float clearance = sample_position.y - terrain;
		vec3 away = position - vec3(sample_position.x, terrain, sample_position.z);
		away.y = 0.0;
		float away_dist = length(away);
		float safe_dist = max(probe_radius + params.agent_radius, 0.001);
		if (clearance < effective_clearance) {
			float range_term = clamp((safe_dist - away_dist) / safe_dist, 0.0, 1.0);
			float clear_term = clamp((effective_clearance - clearance) * safe_inverse(effective_clearance), 0.0, 1.0);
			vec3 repulse = safe_normalize(away);
			avoid += repulse * max(range_term, clear_term);
		}
	}

	return avoid * params.world_avoid_weight;
}

vec3 flock_orbit(vec3 position, vec3 flock_center, vec3 flock_velocity, vec3 target_anchor, float target_active) {
	if (params.orbit_radius <= 0.0001 && params.orbit_rate <= 0.0001) {
		return vec3(0.0);
	}

	vec3 orbit_anchor = flock_center;
	if (target_active > 0.5) {
		orbit_anchor = target_anchor;
	}
	vec3 to_center = position - orbit_anchor;
	vec3 to_center_h = vec3(to_center.x, 0.0, to_center.z);
	float to_center_d2 = dot(to_center_h, to_center_h);
	if (to_center_d2 <= 0.0001) {
		return vec3(0.0);
	}
	float orbit_radius = max(params.orbit_radius, 0.0001);
	float to_center_d = sqrt(to_center_d2);
	vec3 radial = safe_normalize(to_center_h);
	vec3 flock_axis = safe_normalize(vec3(flock_velocity.x, 0.0, flock_velocity.z));
	if (length(flock_axis) <= 0.000001) {
		flock_axis = vec3(0.0, 0.0, 1.0);
	}
	vec3 tangent = safe_normalize(cross(flock_axis, radial));
	if (length(tangent) <= 0.000001) {
		tangent = safe_normalize(vec3(-radial.z, 0.0, radial.x));
	}
	float orbit_strength = params.orbit_rate * safe_inverse(orbit_radius);
	float radius_error = clamp((orbit_radius - to_center_d) * safe_inverse(orbit_radius), -1.0, 1.0);
	return tangent * orbit_strength + radial * radius_error * orbit_strength;
}

void main() {
	uint id = gl_GlobalInvocationID.x;
	int count = int(round(params.agent_count));
	if (count <= 0) {
		return;
	}
	if (int(id) >= count) {
		return;
	}

	vec3 pos = positions_in.data[id].xyz;
	vec3 vel = velocities_in.data[id].xyz;
	float w_pos = positions_in.data[id].w;
	float w_vel = velocities_in.data[id].w;
	float max_force_cap = clamp(params.max_force, 0.0001, 32.0);
	float max_speed_cap = clamp(params.max_speed, 0.0001, 128.0);
	float terrain_height = sample_world_surface_height(pos);
	float clearance_floor = max(max(params.ground_clearance, params.fly_clearance), 0.0001);
	float clearance = pos.y - terrain_height;
	bool terrain_blocked = params.world_surface_has_height > 0.5 && clearance < clearance_floor;
	if (terrain_blocked) {
		pos.y = terrain_height + clearance_floor;
		vel.y = max(vel.y, 0.0);
		clearance = clearance_floor;
	}

	vec3 separation = vec3(0.0);
	vec3 alignment = vec3(0.0);
	vec3 cohesion = vec3(0.0);
	int neighbors = 0;
	float neighbor_radius_sq = max(params.neighbor_radius_sq, 0.0001);
	float separation_radius_sq = max(params.separation_radius_sq, 0.0001);
	vec3 flock_center = vec3(params.flock_center_x, params.flock_center_y, params.flock_center_z);
	vec3 flock_velocity = vec3(params.flock_velocity_x, params.flock_velocity_y, params.flock_velocity_z);

	for (int i = 0; i < count; i++) {
		if (i == int(id)) {
			continue;
		}
		vec3 other_pos = positions_in.data[i].xyz;
		vec3 diff = other_pos - pos;
		float d2 = dot(diff, diff);
		if (d2 <= 0.000001 || d2 > neighbor_radius_sq) {
			continue;
		}
		neighbors += 1;
		alignment += velocities_in.data[i].xyz;
		cohesion += other_pos;
		if (d2 < separation_radius_sq) {
			separation -= safe_normalize(diff) * (neighbor_radius_sq - d2) / neighbor_radius_sq;
		}
	}

	vec3 steering = vec3(0.0);
	if (neighbors > 0) {
		float inv_neighbors = 1.0 / float(neighbors);
		vec3 avg_alignment = alignment * inv_neighbors;
		vec3 avg_cohesion = (cohesion * inv_neighbors) - pos;
		steering += safe_normalize(avg_alignment) * params.alignment_weight;
		steering += safe_normalize(avg_cohesion) * params.cohesion_weight;
		steering += safe_normalize(separation) * params.separation_weight;
	}

	vec3 target_vec = target_intent.data[id].xyz - pos;
	float target_active = clamp(target_intent.data[id].w, 0.0, 1.0);
	if (target_active > 0.0001) {
		steering += safe_normalize(target_vec) * params.target_weight * target_active;
	}

	vec3 avoid_vec = pos - avoidance_intent.data[id].xyz;
	float avoid_active = clamp(avoidance_intent.data[id].w, 0.0, 1.0);
	if (avoid_active > 0.0001) {
		steering += safe_normalize(avoid_vec) * params.avoidance_weight * avoid_active;
	}

	if (params.world_avoid_weight > 0.0001) {
		steering += world_avoidance(pos, vel);
	}

	if (params.altitude_seek_weight > 0.0001 || params.max_altitude > 0.0001) {
		float seek_clearance = clearance_floor;
		float altitude_target = max(params.altitude_seek_target, terrain_height + seek_clearance);
		if (params.max_altitude > 0.0001) {
			altitude_target = min(altitude_target, params.max_altitude);
		}
		float altitude_delta = altitude_target - pos.y;
		if (params.altitude_seek_weight > 0.0001) {
			steering += vec3(0.0, clamp(altitude_delta, -1.0, 1.0), 0.0) * params.altitude_seek_weight;
		}
		if (params.max_altitude > 0.0001 && pos.y > params.max_altitude) {
			steering += vec3(0.0, -1.0, 0.0) * params.world_avoid_weight;
		}
	}

	float dt = clamp(params.dt, 0.0001, 0.05);
	steering += flock_orbit(pos, flock_center, flock_velocity, target_intent.data[id].xyz, target_active) * 0.5;
	if (terrain_blocked && steering.y < 0.0) {
		steering.y = 0.0;
	}
	float below_clearance = clamp((clearance_floor - clearance) * safe_inverse(clearance_floor), 0.0, 1.0);
	float lift_base = max(max(params.max_fly_climb_speed, params.world_avoid_weight), 0.0);
	steering.y += lift_base * mix(0.15, 1.6, below_clearance);
	steering = fallback_if_non_finite(steering, vec3(0.0));
	steering = clamp_length(steering, max_force_cap);
	vec3 next_vel = vel + steering * dt;
	next_vel = clamp_length(next_vel, max_speed_cap);

	if (params.world_surface_has_height > 0.5 && clearance < clearance_floor) {
		float below_ratio = clamp((clearance_floor - clearance) * safe_inverse(clearance_floor), 0.0, 1.0);
		float post_lift = max(params.max_fly_climb_speed, 0.05);
		next_vel.y = max(next_vel.y, post_lift * mix(0.4, 1.8, below_ratio));
	}

	next_vel = fallback_if_non_finite(next_vel, vec3(0.0));
	next_vel = clamp_length(next_vel, max_speed_cap);
	if (clearance < -0.5) {
		next_vel *= 0.5;
		next_vel = fallback_if_non_finite(next_vel, vec3(0.0));
	}

	if (params.world_bounds_radius > 0.0001) {
		float dist = length(pos);
		float limit = params.world_bounds_radius;
		if (dist > limit) {
			vec3 toward_center = safe_normalize(-pos);
			float push = (dist - limit) / max(limit, 0.0001);
			next_vel += toward_center * params.max_force * clamp(push, 0.0, 2.0);
		}
	}
	vec3 next_pos = pos + next_vel * dt;
	if (params.max_altitude > 0.0001) {
		next_pos.y = min(next_pos.y, params.max_altitude);
	}
	if (params.world_surface_has_height > 0.5) {
		float next_clearance = next_pos.y - terrain_height;
		float hard_clearance = max(clearance_floor, 0.001);
		if (next_clearance < hard_clearance) {
			next_pos.y = terrain_height + hard_clearance;
			next_vel.y = max(next_vel.y, 0.0);
		}
	}

	positions_out.data[id] = vec4(next_pos, w_pos);
	velocities_out.data[id] = vec4(next_vel, w_vel);
}
