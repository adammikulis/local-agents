extends Node

const WorldSimulatorScene = preload("res://addons/local_agents/scenes/simulation/app/WorldSimulatorApp.tscn")
const SandboxScenario = preload("res://addons/local_agents/configuration/parameters/simulation/scenarios/SandboxScenario.tres")
const BenchmarkScenario = preload("res://addons/local_agents/configuration/parameters/simulation/scenarios/BenchmarkScenario.tres")

@export var scenario: Resource = SandboxScenario

func _ready() -> void:
	var app = WorldSimulatorScene.instantiate()
	add_child(app)
	var scenario_id = OS.get_environment("LOCAL_AGENTS_SCENARIO").strip_edges().to_lower()
	var selected = scenario
	if scenario_id == "benchmark":
		selected = BenchmarkScenario
	elif scenario_id == "sandbox":
		selected = SandboxScenario
	if app.has_method("apply_scenario_resource"):
		app.call("apply_scenario_resource", selected)
