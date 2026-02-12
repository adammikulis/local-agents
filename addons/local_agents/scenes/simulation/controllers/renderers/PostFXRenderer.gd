extends Node
class_name LocalAgentsPostFXRenderer

const RainPostFXShader = preload("res://addons/local_agents/scenes/simulation/shaders/VoxelRainPostFX.gdshader")

var _rain_fx_layer: CanvasLayer
var _rain_fx_rect: ColorRect
var _rain_fx_material: ShaderMaterial

func clear_generated() -> void:
	if _rain_fx_layer != null and is_instance_valid(_rain_fx_layer):
		_rain_fx_layer.queue_free()
	_rain_fx_layer = null
	_rain_fx_rect = null
	_rain_fx_material = null

func ensure_layer() -> void:
	if _rain_fx_layer != null and is_instance_valid(_rain_fx_layer):
		return
	_rain_fx_layer = CanvasLayer.new()
	_rain_fx_layer.name = "RainPostFX"
	add_child(_rain_fx_layer)
	_rain_fx_rect = ColorRect.new()
	_rain_fx_rect.anchor_left = 0.0
	_rain_fx_rect.anchor_top = 0.0
	_rain_fx_rect.anchor_right = 1.0
	_rain_fx_rect.anchor_bottom = 1.0
	_rain_fx_rect.offset_left = 0.0
	_rain_fx_rect.offset_top = 0.0
	_rain_fx_rect.offset_right = 0.0
	_rain_fx_rect.offset_bottom = 0.0
	_rain_fx_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rain_fx_material = ShaderMaterial.new()
	_rain_fx_material.shader = RainPostFXShader
	_rain_fx_rect.material = _rain_fx_material
	_rain_fx_layer.add_child(_rain_fx_rect)

func update_weather(rain: float, wind: Vector2, wind_speed: float) -> void:
	ensure_layer()
	if _rain_fx_material == null:
		return
	_rain_fx_material.set_shader_parameter("rain_intensity", rain)
	_rain_fx_material.set_shader_parameter("wind_dir", wind)
	_rain_fx_material.set_shader_parameter("wind_speed", wind_speed)

func apply_lightning(lightning_flash: float) -> void:
	if _rain_fx_material != null:
		_rain_fx_material.set_shader_parameter("lightning_flash", lightning_flash)

