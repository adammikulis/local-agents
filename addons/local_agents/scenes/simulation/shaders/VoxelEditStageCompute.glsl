#[compute]
#version 450

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

struct OpEntry {
    int x;
    int y;
    int z;
    int aligned_x;
    int aligned_y;
    int aligned_z;
    int operation;
    uint sequence_low;
    uint sequence_high;
    float value;
    float previous_value;
    float cleave_normal_x;
    float cleave_normal_y;
    float cleave_normal_z;
    float cleave_plane_offset;
    float radius;
    int shape_code;
    uint noise_seed_low;
    uint noise_seed_high;
    float noise_amplitude;
    float noise_frequency;
    int noise_mode_code;
};

struct ChangedEntry {
    int x;
    int y;
    int z;
    uint changed;
    uint sequence_low;
    uint sequence_high;
    float result_value;
    uint reserved;
};

struct ValueEntry {
    int x;
    int y;
    int z;
    float value;
    uint occupied;
    uint next_plus_one;
    uint reserved1;
    uint reserved2;
};

layout(set = 0, binding = 0, std430) readonly buffer OpsBuffer {
    OpEntry entries[];
}
ops_buffer;

layout(set = 0, binding = 1, std430) writeonly buffer OutBuffer {
    ChangedEntry entries[];
}
out_buffer;

layout(set = 0, binding = 2, std430) buffer ParamsBuffer {
    uint op_count;
    int voxel_scale;
    uint value_count;
    uint value_capacity;
    uint hash_capacity;
}
params_buffer;

layout(set = 0, binding = 3, std430) buffer ValueBuffer {
    ValueEntry entries[];
}
value_buffer;

layout(set = 0, binding = 4, std430) buffer ValueHashBuffer {
    uint heads[];
}
value_hash_buffer;

uint hash_u32(uint x) {
    x ^= (x >> 16);
    x *= 0x7feb352du;
    x ^= (x >> 15);
    x *= 0x846ca68bu;
    x ^= (x >> 16);
    return x;
}

float deterministic_noise(const OpEntry op, const int sx, const int sy, const int sz) {
    uint h = hash_u32(op.noise_seed_low ^ hash_u32(op.noise_seed_high + 0x9e3779b9u));
    h = hash_u32(h ^ hash_u32(uint(sx) * 73856093u));
    h = hash_u32(h ^ hash_u32(uint(sy) * 19349663u));
    h = hash_u32(h ^ hash_u32(uint(sz) * 83492791u));
    return (float(h) / 4294967295.0) * 2.0 - 1.0;
}

float fracture_falloff(const OpEntry op, const ChangedEntry entry) {
    if (op.radius <= 1.0) {
        return 1.0;
    }
    const float dx = float(entry.x - op.x);
    const float dy = float(entry.y - op.y);
    const float dz = float(entry.z - op.z);
    const float dist2 = dx * dx + dz * dz + (op.shape_code == 1 ? 0.0 : dy * dy);
    const float radius2 = op.radius * op.radius;
    if (dist2 > radius2) {
        return 0.0;
    }
    const float radius = max(op.radius, 0.000001);
    return max(0.0, 1.0 - sqrt(dist2) / radius);
}

float apply_noise(const OpEntry op, const ChangedEntry entry, const float base_falloff) {
    if (base_falloff <= 0.0) {
        return 0.0;
    }
    if (op.noise_amplitude <= 0.0 || op.noise_frequency <= 0.0) {
        return clamp(base_falloff, 0.0, 1.0);
    }
    const float scaled_x = float(entry.x - op.x) * op.noise_frequency;
    const float scaled_y = float(entry.y - op.y) * op.noise_frequency;
    const float scaled_z = float(entry.z - op.z) * op.noise_frequency;
    const float n = deterministic_noise(
        op,
        int(floor(scaled_x)),
        int(floor(scaled_y)),
        int(floor(scaled_z)));
    const float centered = clamp(1.0 + op.noise_amplitude * n, 0.0, 2.0);
    const float positive_noise = clamp(0.5 + 0.5 * n, 0.0, 1.0);
    if (op.noise_mode_code == 2) { // replace
        return positive_noise;
    }
    if (op.noise_mode_code == 3) { // add
        return clamp(base_falloff + (positive_noise - 0.5) * op.noise_amplitude, 0.0, 1.0);
    }
    if (op.noise_mode_code == 1) { // multiply
        return clamp(base_falloff * centered, 0.0, 1.0);
    }
    return clamp(base_falloff, 0.0, 1.0);
}

uint coord_hash(const int x, const int y, const int z) {
    uint h = hash_u32(uint(x) * 73856093u);
    h = hash_u32(h ^ hash_u32(uint(y) * 19349663u));
    h = hash_u32(h ^ hash_u32(uint(z) * 83492791u));
    return h;
}

bool is_power_of_two_u32(const uint value) {
    return value != 0u && ((value & (value - 1u)) == 0u);
}

void main() {
    if (gl_GlobalInvocationID.x != 0u) {
        return;
    }

    uint value_count = min(params_buffer.value_count, params_buffer.value_capacity);
    for (uint index = 0u; index < params_buffer.op_count; index += 1u) {
        const OpEntry op = ops_buffer.entries[index];

        ChangedEntry entry;
        entry.x = op.aligned_x;
        entry.y = op.aligned_y;
        entry.z = op.aligned_z;

        const uint hash_capacity = max(params_buffer.hash_capacity, 1u);
        const uint hash_value = coord_hash(entry.x, entry.y, entry.z);
        const uint bucket = is_power_of_two_u32(hash_capacity)
            ? (hash_value & (hash_capacity - 1u))
            : (hash_value % hash_capacity);
        uint value_slot = params_buffer.value_capacity;
        uint value_next_plus_one = 0u;
        uint chain = value_hash_buffer.heads[bucket];
        uint guard = 0u;
        while (chain != 0u && guard < params_buffer.value_capacity) {
            const uint value_index = chain - 1u;
            if (value_index >= params_buffer.value_capacity) {
                break;
            }
            const ValueEntry state = value_buffer.entries[value_index];
            if (state.x == entry.x && state.y == entry.y && state.z == entry.z) {
                value_slot = value_index;
                value_next_plus_one = state.next_plus_one;
                break;
            }
            chain = state.next_plus_one;
            guard += 1u;
        }

        float previous_value = 0.0;
        if (value_slot < params_buffer.value_capacity) {
            const ValueEntry existing_state = value_buffer.entries[value_slot];
            value_next_plus_one = existing_state.next_plus_one;
            if (existing_state.occupied != 0u) {
                previous_value = max(existing_state.value, 0.0);
            }
        } else if (value_count < params_buffer.value_capacity) {
            value_slot = value_count;
            value_count += 1u;
            value_next_plus_one = value_hash_buffer.heads[bucket];
            value_hash_buffer.heads[bucket] = value_slot + 1u;
        }

        float next_value = previous_value;
        if (op.operation == 1) {
            next_value = op.value;
        } else if (op.operation == 2) {
            next_value = previous_value + op.value;
        } else if (op.operation == 3) {
            next_value = max(previous_value, op.value);
        } else if (op.operation == 4) {
            next_value = min(previous_value, op.value);
        } else if (op.operation == 5) {
            const float falloff = apply_noise(op, entry, fracture_falloff(op, entry));
            next_value = previous_value - abs(op.value) * falloff;
        } else if (op.operation == 6) {
            const float signed_distance = op.cleave_normal_x * float(entry.x)
                + op.cleave_normal_y * float(entry.y)
                + op.cleave_normal_z * float(entry.z)
                - op.cleave_plane_offset;
            if (signed_distance >= 0.0) {
                float falloff = fracture_falloff(op, entry);
                if (op.radius > 1.0) {
                    const float directional_component = clamp(signed_distance / max(1.0, op.radius), 0.0, 1.0);
                    falloff *= (0.25 + 0.75 * directional_component);
                }
                falloff = apply_noise(op, entry, falloff);
                next_value = previous_value - abs(op.value) * falloff;
            }
        }

        next_value = max(next_value, 0.0);
        if (value_slot < params_buffer.value_capacity) {
            ValueEntry next_state;
            next_state.x = entry.x;
            next_state.y = entry.y;
            next_state.z = entry.z;
            next_state.value = next_value;
            next_state.occupied = next_value > 0.0 ? 1u : 0u;
            next_state.next_plus_one = value_next_plus_one;
            next_state.reserved1 = 0u;
            next_state.reserved2 = 0u;
            value_buffer.entries[value_slot] = next_state;
        }

        entry.changed = abs(next_value - previous_value) > 0.000001 ? 1u : 0u;
        entry.sequence_low = op.sequence_low;
        entry.sequence_high = op.sequence_high;
        entry.result_value = next_value;
        entry.reserved = 0u;
        out_buffer.entries[index] = entry;
    }

    params_buffer.value_count = value_count;
}
