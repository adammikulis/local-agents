extends SceneTree

## Numeric half of scripts/check_face_area.sh. Builds the grid and asks whether the face-area table closes:
## shared faces agree from both ends, radial faces sum to 4*pi*r^2, the radial pair reproduces the cell
## volume, and the corner set the lateral arcs are measured between reproduces the solid angle.
## Loaded by path, not by class_name, so the gate does not depend on an editor scan having run.

const GRID_PATH: String = "res://addons/local_agents/sim/sphere/SphereGrid.gd"
const PROFILES_PATH: String = "res://addons/local_agents/sim/sphere/SphereGridProfiles.gd"
const LIVE_RES: int = 24
const LIVE_DEPTH: int = 20


func _init() -> void:
	var grid_script: GDScript = load(GRID_PATH)
	var profiles: GDScript = load(PROFILES_PATH)
	if grid_script == null or profiles == null:
		print("FACE_AREA=", JSON.stringify({"ok": false, "reason": "SphereGrid.gd/SphereGridProfiles.gd did not load"}))
		quit(2)
		return
	var arms: Dictionary = {}
	var ok: bool = true
	ok = _arm(grid_script, arms, "small", 4, 6, 100.0, 8.0, PackedFloat32Array()) and ok
	ok = _arm(grid_script, arms, "live", LIVE_RES, LIVE_DEPTH, 170.0, 8.0, PackedFloat32Array()) and ok
	var profile: PackedFloat32Array = profiles.surface_focus(LIVE_DEPTH, 8.0, LIVE_DEPTH / 2)
	ok = _arm(grid_script, arms, "live_graded", LIVE_RES, LIVE_DEPTH, 170.0, 8.0, profile) and ok
	print("FACE_AREA=", JSON.stringify({"ok": ok, "arms": arms}))
	quit(0 if ok else 1)


func _arm(grid_script: GDScript, arms: Dictionary, tag: String, res: int, depth: int, core_r: float,
		mean_dr: float, profile: PackedFloat32Array) -> bool:
	var grid: RefCounted = grid_script.new()
	grid.build(res, depth, core_r, mean_dr, Vector3.ZERO, profile)
	var v: Dictionary = grid.validate_face_areas()
	var corners: Dictionary = grid.validate_corners()
	var bad_axis: int = int(corners.get("axis_violations", -1))
	var centre_rel: float = float(corners.get("centre_rel", INF))
	var ok: bool = bool(v.get("ok", false)) and bad_axis == 0 and centre_rel < 1.0
	arms[tag] = {
		"ok": ok,
		"sized": bool(v.get("sized", false)),
		"reciprocity_rel": snappedf(float(v.get("reciprocity_rel", INF)), 1.0e-12),
		"shell_close_rel": snappedf(float(v.get("shell_close_rel", INF)), 1.0e-12),
		"volume_rel": snappedf(float(v.get("volume_rel", INF)), 1.0e-12),
		"corner_axis_violations": bad_axis,
		"corner_centre_rel": snappedf(centre_rel, 1.0e-9),
		"area_min": float(v.get("area_min", 0.0)),
	}
	return ok
