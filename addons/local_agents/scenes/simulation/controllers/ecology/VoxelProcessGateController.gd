extends RefCounted
class_name LocalAgentsVoxelProcessGateController

var _owner: Variant
var _accumulators: Dictionary = {}

func setup(owner: Variant) -> void:
	_owner = owner

func clear() -> void:
	_accumulators.clear()

func should_process(system_id: String, voxel: Vector3i, delta: float, base_interval_seconds: float, activity: float) -> bool:
	if _owner == null:
		return true
	if not bool(_owner.voxel_process_gating_enabled):
		return true
	var system_key := system_id.strip_edges().to_lower()
	if system_key == "":
		system_key = "default"
	var voxel_key := _voxel_key(voxel)
	var by_voxel: Dictionary = _accumulators.get(system_key, {})
	var acc := float(by_voxel.get(voxel_key, 0.0)) + maxf(0.0, delta)
	var interval := _target_interval(base_interval_seconds, activity)
	if acc + 0.000001 < interval:
		by_voxel[voxel_key] = acc
		_accumulators[system_key] = by_voxel
		return false
	by_voxel[voxel_key] = fmod(acc, interval)
	_accumulators[system_key] = by_voxel
	return true

func _target_interval(base_interval_seconds: float, activity: float) -> float:
	var min_interval := clampf(float(_owner.voxel_tick_min_interval_seconds), 0.01, 1.2)
	var max_interval := clampf(float(_owner.voxel_tick_max_interval_seconds), min_interval, 3.0)
	var base_interval := clampf(base_interval_seconds, min_interval, max_interval)
	if not bool(_owner.voxel_dynamic_tick_rate_enabled):
		return base_interval
	var busy := clampf(activity, 0.0, 1.0)
	var dynamic_interval := lerpf(max_interval, min_interval, busy)
	return clampf(lerpf(base_interval, dynamic_interval, 0.8), min_interval, max_interval)

func _voxel_key(voxel: Vector3i) -> String:
	return "%d:%d:%d" % [voxel.x, voxel.y, voxel.z]
