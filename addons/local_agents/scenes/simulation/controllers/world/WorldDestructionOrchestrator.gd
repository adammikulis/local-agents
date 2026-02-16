extends RefCounted
class_name LocalAgentsWorldDestructionOrchestrator

const SimulationVoxelTerrainMutatorScript = preload("res://addons/local_agents/simulation/controller/SimulationVoxelTerrainMutator.gd")
const WorldNativeVoxelDispatchRuntimeScript = preload("res://addons/local_agents/scenes/simulation/controllers/world/WorldNativeVoxelDispatchRuntime.gd")
const WorldDispatchContractsScript = preload("res://addons/local_agents/scenes/simulation/controllers/world/WorldDispatchContracts.gd")

func apply_stage_result(
	simulation_controller: Node,
	native_voxel_dispatch_runtime: Dictionary,
	tick: int,
	stage_payload: Dictionary,
	sync_environment_callable: Callable
) -> bool:
	var mutation = SimulationVoxelTerrainMutatorScript.apply_native_voxel_stage_delta(simulation_controller, tick, stage_payload)
	WorldNativeVoxelDispatchRuntimeScript.record_mutation(native_voxel_dispatch_runtime, stage_payload, mutation, Engine.get_process_frames())
	if not bool(mutation.get("changed", false)):
		return false
	if sync_environment_callable.is_valid():
		sync_environment_callable.call(WorldDispatchContractsScript.build_mutation_sync_state(simulation_controller, tick, mutation))
	return true
