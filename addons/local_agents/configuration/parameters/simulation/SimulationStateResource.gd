extends Resource
class_name LocalAgentsSimulationStateResource

const WorldSnapshotResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/WorldSnapshotResource.gd")
const GeologySnapshotResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/GeologySnapshotResource.gd")

@export var sim_tick: int = 0
@export var simulated_seconds: float = 0.0
@export var simulation_accumulator: float = 0.0
@export var active_branch_id: String = "main"
@export var landslide_count: int = 0
@export var world_snapshot: LocalAgentsWorldSnapshotResource = WorldSnapshotResourceScript.new()
@export var geology_snapshot: LocalAgentsGeologySnapshotResource = GeologySnapshotResourceScript.new()
@export var transform_state_snapshot: Dictionary = {}
@export var transform_diagnostics_snapshot: Dictionary = {}
@export var pass_descriptor: Dictionary = {}
@export var material_model: Dictionary = {}
@export var emitter_model: Dictionary = {}
@export var dispatch_contract_status: Dictionary = {}

func reset_runtime_state() -> void:
	sim_tick = 0
	simulated_seconds = 0.0
	simulation_accumulator = 0.0
	active_branch_id = "main"
	landslide_count = 0
	world_snapshot = WorldSnapshotResourceScript.new()
	geology_snapshot = GeologySnapshotResourceScript.new()
	transform_state_snapshot = {}
	transform_diagnostics_snapshot = {}
	pass_descriptor = {}
	material_model = {}
	emitter_model = {}
	dispatch_contract_status = {}
