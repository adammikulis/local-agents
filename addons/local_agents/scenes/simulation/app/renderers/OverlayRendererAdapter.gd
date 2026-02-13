extends RefCounted
class_name LocalAgentsOverlayRendererAdapter

func apply_visibility(debug_overlay_root: Node3D, paths: bool, resources: bool, conflicts: bool, smell: bool, wind: bool, temperature: bool) -> void:
	if debug_overlay_root == null:
		return
	if debug_overlay_root.has_method("set_visibility_flags"):
		debug_overlay_root.call("set_visibility_flags", paths, resources, conflicts, smell, wind, temperature)
