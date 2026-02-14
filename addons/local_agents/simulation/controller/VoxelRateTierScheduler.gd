extends RefCounted
class_name LocalAgentsVoxelRateTierScheduler

const _TIER_ORDER := ["high", "medium", "low"]

var _enabled: bool = true
var _dynamic_enabled: bool = true
var _min_interval_seconds: float = 0.05
var _max_interval_seconds: float = 0.6
var _tier_elapsed := {"high": 0.0, "medium": 0.0, "low": 0.0}

func configure(enabled: bool, dynamic_enabled: bool, min_interval_seconds: float, max_interval_seconds: float) -> void:
	_enabled = enabled
	_dynamic_enabled = dynamic_enabled
	_min_interval_seconds = clampf(min_interval_seconds, 0.01, 1.2)
	_max_interval_seconds = clampf(max_interval_seconds, _min_interval_seconds, 3.0)

func advance(delta: float, compute_budget_scale: float) -> Array:
	if not _enabled:
		return []
	var safe_delta = maxf(0.0, delta)
	var base_budget = clampf(compute_budget_scale, 0.05, 1.0)
	var due: Array = []
	for tier_variant in _TIER_ORDER:
		var tier_id = String(tier_variant)
		_tier_elapsed[tier_id] = float(_tier_elapsed.get(tier_id, 0.0)) + safe_delta
		var interval = _interval_for_tier(tier_id, base_budget)
		if float(_tier_elapsed.get(tier_id, 0.0)) < interval:
			continue
		_tier_elapsed[tier_id] = fmod(float(_tier_elapsed.get(tier_id, 0.0)), interval)
		due.append({
			"tier_id": tier_id,
			"interval_seconds": interval,
			"compute_budget_scale": _budget_for_tier(tier_id, base_budget),
		})
	return due

func _interval_for_tier(tier_id: String, budget: float) -> float:
	var blend := 1.0
	if tier_id == "high":
		blend = 0.0
	elif tier_id == "medium":
		blend = 0.5
	var tier_interval = lerpf(_min_interval_seconds, _max_interval_seconds, blend)
	if not _dynamic_enabled:
		return tier_interval
	var load_scale = lerpf(1.35, 0.75, budget)
	return clampf(tier_interval * load_scale, _min_interval_seconds, _max_interval_seconds)

func _budget_for_tier(tier_id: String, base_budget: float) -> float:
	if tier_id == "high":
		return base_budget
	if tier_id == "medium":
		return clampf(base_budget * 0.8, 0.05, 1.0)
	return clampf(base_budget * 0.6, 0.05, 1.0)
