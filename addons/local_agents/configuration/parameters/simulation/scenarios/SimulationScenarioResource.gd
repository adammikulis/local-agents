extends Resource
class_name LocalAgentsSimulationScenarioResource

@export var scenario_id: String = "sandbox"
@export var display_name: String = "Sandbox"
@export var seed_text: String = "sandbox_seed"
@export var auto_generate_on_ready: bool = true
@export var start_paused: bool = false
@export var backend_mode: String = "gpu_hybrid"
@export var world_width: int = 96
@export var world_depth: int = 96
@export var world_height: int = 48
@export var sea_level: int = 12
