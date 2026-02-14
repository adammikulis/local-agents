extends Node

const WorldSimulationScene = preload("res://addons/local_agents/scenes/simulation/WorldSimulation.tscn")

func _ready() -> void:
	var simulation = WorldSimulationScene.instantiate()
	add_child(simulation)
