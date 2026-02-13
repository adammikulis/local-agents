extends RefCounted
class_name LocalAgentsMaterialFlowNativeStageHelpers

const _DEFAULT_CAMERA_DISTANCE := 0.0
const _DEFAULT_ZOOM_FACTOR := 0.0
const _DEFAULT_UNIFORMITY_SCORE := 0.0
const _DEFAULT_COMPUTE_BUDGET_SCALE := 1.0

static func sanitize_native_view_metrics(metrics: Dictionary) -> Dictionary:
	var source: Dictionary = metrics if metrics != null else {}
	return {
		"camera_distance": maxf(0.0, float(source.get("camera_distance", _DEFAULT_CAMERA_DISTANCE))),
		"zoom_factor": clampf(float(source.get("zoom_factor", _DEFAULT_ZOOM_FACTOR)), 0.0, 1.0),
		"uniformity_score": clampf(float(source.get("uniformity_score", _DEFAULT_UNIFORMITY_SCORE)), 0.0, 1.0),
		"compute_budget_scale": clampf(float(source.get("compute_budget_scale", _DEFAULT_COMPUTE_BUDGET_SCALE)), 0.0, 1.0),
	}

static func build_environment_stage_payload(
	tick: int,
	delta: float,
	environment_snapshot: Dictionary,
	hydrology_snapshot: Dictionary,
	weather_snapshot: Dictionary,
	local_activity: Dictionary,
	native_view_metrics: Dictionary = {},
	physics_contacts: Array = []
) -> Dictionary:
	var payload := {
		"tick": tick,
		"delta": delta,
		"environment": environment_snapshot.duplicate(true),
		"hydrology": hydrology_snapshot.duplicate(true),
		"weather": weather_snapshot.duplicate(true),
		"local_activity": local_activity.duplicate(true),
	}
	if not physics_contacts.is_empty():
		payload["physics_contacts"] = physics_contacts.duplicate(true)
	payload.merge(sanitize_native_view_metrics(native_view_metrics), true)
	return payload
