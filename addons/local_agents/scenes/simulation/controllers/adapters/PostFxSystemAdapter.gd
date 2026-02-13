extends RefCounted
class_name PostFxSystemAdapter

func ensure_rain_post_fx(controller: Node) -> void:
	if not controller.rain_post_fx_enabled:
		if controller._post_fx_renderer != null:
			controller._post_fx_renderer.clear_generated()
		return
	controller._ensure_renderer_nodes()
	controller._post_fx_renderer.ensure_layer()

func update_rain_post_fx_weather(controller: Node, rain: float, wind: Vector2, wind_speed: float) -> void:
	if not controller.rain_post_fx_enabled:
		return
	controller._ensure_renderer_nodes()
	controller._post_fx_renderer.update_weather(rain, wind, wind_speed)
	controller._post_fx_renderer.apply_lightning(controller._lightning_flash)
	controller._ocean_adapter.apply_ocean_material_uniforms(controller)
