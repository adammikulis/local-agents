extends Node3D

@onready var simulation_controller: Node = $SimulationController
@onready var environment_controller: Node3D = $EnvironmentController
@onready var settlement_controller: Node3D = $SettlementController
@onready var villager_controller: Node3D = $VillagerController
@onready var culture_controller: Node3D = $CultureController

func _ready() -> void:
	# Intentionally minimal skeleton; systems are wired incrementally by the simulation vertical slice.
	pass
