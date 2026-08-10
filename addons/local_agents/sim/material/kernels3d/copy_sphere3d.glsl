#[compute]
#version 450


layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer Src { float src[]; };
layout(set = 0, binding = 1, std430) restrict writeonly buffer Dst { float dst[]; };

layout(push_constant, std430) uniform Params {
	uint cell_count;
	uint pad0;
	uint pad1;
	uint pad2;
} params;

void main() {
	uint idx = gl_GlobalInvocationID.x;
	if (idx >= params.cell_count) {
		return;
	}
	dst[idx] = src[idx];
}
