extends Resource
class_name LocalAgentsConfigList

@export var model_configurations: Array[LocalAgentsModelParams] = []
@export var inference_configurations: Array[LocalAgentsInferenceParams] = []
@export var current_model_config: LocalAgentsModelParams
@export var last_good_model_config: LocalAgentsModelParams
@export var current_inference_config: LocalAgentsInferenceParams
@export var last_good_inference_config: LocalAgentsInferenceParams
@export var autoload_last_good_model_config: bool = false
@export var autoload_last_good_inference_config: bool = false
