extends RefCounted
class_name LightingSystemAdapter

func process(controller: Node, delta: float) -> void:
	controller._lightning_flash = maxf(0.0, controller._lightning_flash - delta * 2.6)
	if not is_equal_approx(controller._lightning_flash, controller._last_lightning_uniform):
		controller._last_lightning_uniform = controller._lightning_flash
		update_lightning_uniforms(controller)

func trigger_lightning(controller: Node, intensity: float = 1.0) -> void:
	controller._lightning_flash = clampf(maxf(controller._lightning_flash, intensity), 0.0, 2.0)
	controller._last_lightning_uniform = -1.0
	update_lightning_uniforms(controller)

func update_lightning_uniforms(controller: Node) -> void:
	controller._ensure_renderer_nodes()
	controller._river_renderer.apply_lightning(controller._lightning_flash)
	controller._cloud_renderer.apply_lightning(controller._lightning_flash)
	controller._post_fx_renderer.apply_lightning(controller._lightning_flash)
	controller._ocean_adapter.apply_ocean_material_uniforms(controller)
