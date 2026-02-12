extends Resource
class_name LocalAgentsConfigList

@export var model_configurations: Array = []
@export var inference_configurations: Array = []
@export var current_model_config: Resource
@export var last_good_model_config: Resource
@export var current_inference_config: Resource
@export var last_good_inference_config: Resource
@export var autoload_last_good_model_config: bool = false
@export var autoload_last_good_inference_config: bool = false
