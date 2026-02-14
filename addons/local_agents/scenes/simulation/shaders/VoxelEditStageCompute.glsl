#[compute]
#version 450

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

struct OpEntry {
    int x;
    int y;
    int z;
    int operation;
    uint sequence_low;
    uint sequence_high;
    float value;
    float previous_value;
    float cleave_normal_x;
    float cleave_normal_y;
    float cleave_normal_z;
    float cleave_plane_offset;
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

layout(set = 0, binding = 0, std430) readonly buffer OpsBuffer {
    OpEntry entries[];
}
ops_buffer;

layout(set = 0, binding = 1, std430) writeonly buffer OutBuffer {
    ChangedEntry entries[];
}
out_buffer;

layout(set = 0, binding = 2, std430) readonly buffer ParamsBuffer {
    uint op_count;
    int voxel_scale;
    int reserved0;
    int reserved1;
}
params_buffer;

int floor_div_int(const int value, const int divisor) {
    if (divisor <= 0) {
        return 0;
    }
    if (value >= 0) {
        return value / divisor;
    }
    return -(((-value) + divisor - 1) / divisor);
}

void main() {
    const uint index = gl_GlobalInvocationID.x;
    if (index >= params_buffer.op_count) {
        return;
    }

    const int scale = max(1, params_buffer.voxel_scale);
    const OpEntry op = ops_buffer.entries[index];

    ChangedEntry entry;
    entry.x = floor_div_int(op.x, scale) * scale;
    entry.y = floor_div_int(op.y, scale) * scale;
    entry.z = floor_div_int(op.z, scale) * scale;
    const float previous_value = max(op.previous_value, 0.0);
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
        next_value = previous_value - abs(op.value);
    } else if (op.operation == 6) {
        const float signed_distance = op.cleave_normal_x * float(entry.x)
            + op.cleave_normal_y * float(entry.y)
            + op.cleave_normal_z * float(entry.z)
            - op.cleave_plane_offset;
        if (signed_distance >= 0.0) {
            next_value = previous_value - abs(op.value);
        }
    }
    next_value = max(next_value, 0.0);
    entry.changed = abs(next_value - previous_value) > 0.000001 ? 1u : 0u;
    entry.sequence_low = op.sequence_low;
    entry.sequence_high = op.sequence_high;
    entry.result_value = next_value;
    entry.reserved = 0u;
    out_buffer.entries[index] = entry;
}
