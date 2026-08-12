class_name LALodStride
extends RefCounted


static func relevance_from_distance(distance: float, characteristic_distance: float) -> float:
	return characteristic_distance / (characteristic_distance + maxf(distance, 0.0))


static func stride_for(relevance: float, max_stride: int, base_stride: int = 1) -> int:
	var r: float = maxf(relevance, float(base_stride) / float(max_stride))
	return clampi(int(round(float(base_stride) / r)), base_stride, max_stride)


static func should_run(tick: int, phase: int, stride: int) -> bool:
	return (tick + phase) % stride == 0
