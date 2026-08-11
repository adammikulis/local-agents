extends Resource
class_name LAConfigList

## The saved set of model profiles and inference presets, plus which one is active.
##
## Persisted to `user://local_agents/config/ConfigList.tres`, seeded on first run from the read-only
## copy shipped in this directory. AgentManager owns reading and writing it.
##
## The `current_*` / `last_good_*` split exists so a preset that fails to apply does not poison
## startup: `current_*` is whatever the user last selected, `last_good_*` is the newest one that was
## actually applied without error, and only that one is eligible for autoload.
##
## Types are explicit (LocalAgentModelProfile / LocalAgentInferenceParams rather than bare Resource)
## so a wrong assignment fails where it is made instead of silently no-op'ing at a later cast.

@export_group("Saved configurations")
## Every model profile the user has saved. Shown in the Model Config panel's dropdown.
@export var model_configurations: Array[LocalAgentModelProfile] = []
## Every sampling preset the user has saved. Shown in the Inference Config panel's dropdown.
@export var inference_configurations: Array[LocalAgentInferenceParams] = []

@export_group("Active")
## The profile currently selected in the editor panel.
@export var current_model_config: LocalAgentModelProfile
## The sampling preset currently selected in the editor panel.
@export var current_inference_config: LocalAgentInferenceParams

@export_group("Last known good")
## The most recent profile that applied cleanly. Only this one is eligible for autoload.
@export var last_good_model_config: LocalAgentModelProfile
## The most recent sampling preset that applied cleanly.
@export var last_good_inference_config: LocalAgentInferenceParams

@export_group("Startup")
## Re-apply `last_good_model_config` automatically when the project starts.
@export var autoload_last_good_model_config: bool = false
## Re-apply `last_good_inference_config` automatically when the project starts.
@export var autoload_last_good_inference_config: bool = false
