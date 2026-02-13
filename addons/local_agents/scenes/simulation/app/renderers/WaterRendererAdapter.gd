extends RefCounted
class_name LocalAgentsWaterRendererAdapter

func apply_state(environment_controller: Node3D, weather_snapshot: Dictionary, solar_snapshot: Dictionary) -> void:
	if environment_controller == null:
		return
	if environment_controller.has_method("set_weather_state"):
		environment_controller.call("set_weather_state", weather_snapshot)
	if environment_controller.has_method("set_solar_state"):
		environment_controller.call("set_solar_state", solar_snapshot)

func apply_shader_params(environment_controller: Node3D, params: Dictionary) -> void:
	if environment_controller == null:
		return
	if environment_controller.has_method("set_water_shader_params"):
		environment_controller.call("set_water_shader_params", params)
