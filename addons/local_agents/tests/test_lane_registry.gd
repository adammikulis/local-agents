@tool
extends RefCounted
class_name LocalAgentsTestLaneRegistry

const DETERMINISTIC_TESTS := [
	"res://addons/local_agents/tests/test_smoke_agent.gd",
	"res://addons/local_agents/tests/test_agent_utilities.gd",
	"res://addons/local_agents/tests/test_field_registry_config_resource.gd",
	"res://addons/local_agents/tests/test_deterministic_simulation.gd",
	"res://addons/local_agents/tests/test_simulation_worldgen_determinism.gd",
	"res://addons/local_agents/tests/test_simulation_flowmap_bake.gd",
	"res://addons/local_agents/tests/test_simulation_erosion_delta_tiles.gd",
	"res://addons/local_agents/tests/test_simulation_environment_signal_determinism.gd",
	"res://addons/local_agents/tests/test_freeze_thaw_erosion.gd",
	"res://addons/local_agents/tests/test_solar_albedo_from_rgba.gd",
	"res://addons/local_agents/tests/test_wind_air_column_solar_heating.gd",
	"res://addons/local_agents/tests/test_simulation_voxel_terrain_generation.gd",
	"res://addons/local_agents/tests/test_simulation_water_first_spawn.gd",
	"res://addons/local_agents/tests/test_simulation_branching.gd",
	"res://addons/local_agents/tests/test_simulation_rewind_branch_diff.gd",
	"res://addons/local_agents/tests/test_simulation_path_logistics.gd",
	"res://addons/local_agents/tests/test_simulation_settlement_growth.gd",
	"res://addons/local_agents/tests/test_simulation_oral_tradition.gd",
	"res://addons/local_agents/tests/test_simulation_culture_policy_effects.gd",
	"res://addons/local_agents/tests/test_cultural_driver_json_contract.gd",
	"res://addons/local_agents/tests/test_simulation_cognition_contract.gd",
	"res://addons/local_agents/tests/test_simulation_path_decay.gd",
	"res://addons/local_agents/tests/test_path_traversal_profile.gd",
	"res://addons/local_agents/tests/test_wind_field_system.gd",
	"res://addons/local_agents/tests/test_smell_field_system.gd",
	"res://addons/local_agents/tests/test_ecology_shelter_capabilities.gd",
	"res://addons/local_agents/tests/test_structure_lifecycle_depletion.gd",
	"res://addons/local_agents/tests/test_simulation_dream_labeling.gd",
	"res://addons/local_agents/tests/test_simulation_resource_ledgers.gd",
	"res://addons/local_agents/tests/test_simulation_economy_events.gd",
]

const INTEGRATION_TESTS := [
	"res://addons/local_agents/tests/test_simulation_vertical_slice_30day.gd",
	"res://addons/local_agents/tests/test_world_simulator_app_loop.gd",
]

const RUNTIME_HEAVY_TESTS := [
	"res://addons/local_agents/tests/test_simulation_villager_cognition.gd",
	"res://addons/local_agents/tests/test_simulation_no_empty_generation.gd",
	"res://addons/local_agents/tests/test_simulation_cognition_trace_isolation.gd",
	"res://addons/local_agents/tests/test_llama_server_e2e.gd",
	"res://addons/local_agents/tests/test_agent_integration.gd",
	"res://addons/local_agents/tests/test_agent_runtime_heavy.gd",
]

const PERF_BENCHMARKS := [
	"res://addons/local_agents/tests/benchmark_voxel_pipeline.gd",
]
