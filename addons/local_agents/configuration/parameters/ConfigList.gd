extends Resource
class_name LAConfigList


@export_group("Saved configurations")
@export var model_configurations: Array[LocalAgentModelProfile] = []
@export var inference_configurations: Array[LocalAgentInferenceParams] = []

@export_group("Active")
@export var current_model_config: LocalAgentModelProfile
@export var current_inference_config: LocalAgentInferenceParams

@export_group("Last known good")
@export var last_good_model_config: LocalAgentModelProfile
@export var last_good_inference_config: LocalAgentInferenceParams

@export_group("Startup")
## Re-apply `last_good_model_config` automatically when the project starts.
@export var autoload_last_good_model_config: bool = false
## Re-apply `last_good_inference_config` automatically when the project starts.
@export var autoload_last_good_inference_config: bool = false
