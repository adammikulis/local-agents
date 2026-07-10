#[compute]
#version 450

// Trivial element-wise copy (src -> dst) over the flat cell array. Used to fold a scratch-buffer gather
// result back into a shared ping-pong buffer WITHOUT consuming a parity flip: a gather kernel must write a
// buffer other than the one it reads (race-free), but some passes need the result in-place in the SAME slot
// they read from. Pattern: gather LIVE -> scratch, then copy scratch -> LIVE. Net zero flips.

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
