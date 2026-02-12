extends Node3D

@onready var simulation_controller: Node = $SimulationController
@onready var environment_controller: Node3D = $EnvironmentController
@onready var settlement_controller: Node3D = $SettlementController
@onready var villager_controller: Node3D = $VillagerController
@onready var culture_controller: Node3D = $CultureController
@export var world_seed_text: String = "neolithic_vertical_slice"
@export var auto_generate_on_ready: bool = true

func _ready() -> void:
	if not auto_generate_on_ready:
		return
	if simulation_controller.has_method("configure"):
		simulation_controller.configure(world_seed_text, false, false)
	if not simulation_controller.has_method("configure_environment"):
		return
	var setup: Dictionary = simulation_controller.configure_environment()
	if not bool(setup.get("ok", false)):
		return
	if environment_controller.has_method("apply_generation_data"):
		environment_controller.apply_generation_data(
			setup.get("environment", {}),
			setup.get("hydrology", {})
		)
	if settlement_controller.has_method("spawn_initial_settlement"):
		settlement_controller.spawn_initial_settlement(setup.get("spawn", {}))
