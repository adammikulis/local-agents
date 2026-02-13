extends RefCounted

func apply_cloud_and_debug_quality(host) -> void:
	if host._environment_controller != null and host._environment_controller.has_method("set_cloud_quality_settings"):
		var density = float(host._cloud_density_spin.value)
		if not host._clouds_enabled:
			density = 0.0
		var tier = "medium"
		match host._cloud_quality_option.selected:
			0:
				tier = "low"
			1:
				tier = "medium"
			2:
				tier = "high"
			_:
				tier = "ultra"
		host._environment_controller.call("set_cloud_quality_settings", tier, density)
	if host._ecology_controller != null and host._ecology_controller.has_method("set_debug_quality"):
		host._ecology_controller.call("set_debug_quality", float(host._debug_density_spin.value))
