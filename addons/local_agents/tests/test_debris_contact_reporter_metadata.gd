@tool
extends RefCounted

const DebrisContactReporterScript := preload("res://addons/local_agents/scenes/simulation/controllers/world/DebrisContactReporter.gd")

func run_test(_tree: SceneTree) -> bool:
	var reporter := DebrisContactReporterScript.new()
	var source_row: Dictionary = {
		"body_id": 0,
		"collider_id": 0,
		"contact_point": Vector3(1.0, 2.0, 3.0),
		"contact_impulse": 1.5,
		"relative_speed": 2.0,
	}
	var normalized: Dictionary = reporter._normalize_dispatch_row(source_row, 40, null)
	var ok := true
	ok = _assert(String(normalized.get("contact_source", "")) == "fracture_dynamic", "Reporter normalization should assign default fracture contact_source when debris root is unavailable.") and ok
	ok = _assert(String(normalized.get("projectile_kind", "")) == "voxel_chunk", "Reporter normalization should default projectile_kind to voxel_chunk.") and ok
	ok = _assert(String(normalized.get("projectile_density_tag", "")) == "dense", "Reporter normalization should default projectile_density_tag to dense.") and ok
	ok = _assert(String(normalized.get("projectile_hardness_tag", "")) == "hard", "Reporter normalization should default projectile_hardness_tag to hard.") and ok
	ok = _assert(String(normalized.get("failure_emission_profile", "")) == "dense_hard_voxel_chunk", "Reporter normalization should default failure_emission_profile.") and ok
	ok = _assert(String(normalized.get("projectile_material_tag", "")) == "dense_voxel", "Reporter normalization should default projectile_material_tag.") and ok
	ok = _assert(_is_approx(float(normalized.get("projectile_radius", 0.0)), 0.07), "Reporter normalization should default projectile_radius to launcher baseline.") and ok
	ok = _assert(_is_approx(float(normalized.get("body_mass", 0.0)), 0.2), "Reporter normalization should default body_mass to launcher baseline.") and ok
	ok = _assert(int(normalized.get("deadline_frame", -1)) == 46, "Reporter normalization should default deadline_frame to frame + mutation window.") and ok
	return ok

func _is_approx(lhs: float, rhs: float, epsilon: float = 1.0e-6) -> bool:
	return absf(lhs - rhs) <= epsilon

func _assert(condition: bool, message: String) -> bool:
	if not condition:
		push_error(message)
	return condition
