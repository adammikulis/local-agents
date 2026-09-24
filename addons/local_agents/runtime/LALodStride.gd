class_name LALodStride
extends RefCounted


static func relevance_from_distance(distance: float, characteristic_distance: float) -> float:
	return characteristic_distance / (characteristic_distance + maxf(distance, 0.0))


static func stride_for(relevance: float, max_stride: int, base_stride: int = 1) -> int:
	var r: float = maxf(relevance, float(base_stride) / float(max_stride))
	return clampi(int(round(float(base_stride) / r)), base_stride, max_stride)


## True on this member's frames of a `stride`. `phase` is any per-member integer (an instance id); it is
## mixed first, since ids advance in fixed steps that share factors with the stride and would put the
## whole population on the same frame.
static func should_run(tick: int, phase: int, stride: int) -> bool:
	return (tick + _mix(phase)) % stride == 0


## MurmurHash3's 32-bit finalizer over both halves of the id, non-negative.
static func _mix(v: int) -> int:
	var h: int = (v ^ (v >> 32)) & 0xFFFFFFFF
	h = ((h ^ (h >> 16)) * 0x85EBCA6B) & 0xFFFFFFFF
	h = ((h ^ (h >> 13)) * 0xC2B2AE35) & 0xFFFFFFFF
	return (h ^ (h >> 16)) & 0x7FFFFFFF
