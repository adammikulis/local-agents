extends RefCounted
class_name PostFxSystemAdapter

func ensure_transform_post_fx(controller: Node) -> void:
	if not _is_transform_post_fx_enabled(controller):
		if controller._post_fx_renderer != null:
			controller._post_fx_renderer.clear_generated()
		return
	controller._ensure_renderer_nodes()
	controller._post_fx_renderer.ensure_layer()

func update_transform_post_fx_state(controller: Node, stage_intensity: float, transform_vector: Vector2, transform_speed: float) -> void:
	if not _is_transform_post_fx_enabled(controller):
		return
	controller._ensure_renderer_nodes()
	controller._post_fx_renderer.update_transform_stage(stage_intensity, transform_vector, transform_speed)
	controller._post_fx_renderer.apply_lightning(controller._lightning_flash)
	controller._ocean_adapter.apply_ocean_material_uniforms(controller)

func _is_transform_post_fx_enabled(controller: Node) -> bool:
	var generic_enabled = controller.get("transform_post_fx_enabled")
	if generic_enabled != null:
		return bool(generic_enabled)
	return bool(controller.get("rain_post_fx_enabled"))
