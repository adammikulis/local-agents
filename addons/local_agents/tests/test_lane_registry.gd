@tool
extends RefCounted
class_name LocalAgentsTestLaneRegistry

# Test lanes for the LLM/agent/audio stack. The old homegrown ecosystem/settlement
# simulation + native voxel-op tests were removed with that stack, so these lanes now
# cover only the shipped subsystems (agent runtime, llama server, graph, audio).

const DETERMINISTIC_TESTS: Array[String] = [
	"res://addons/local_agents/tests/test_smoke_agent.gd",
	"res://addons/local_agents/tests/test_agent_utilities.gd",
	"res://addons/local_agents/tests/test_synth_dsp.gd",
	"res://addons/local_agents/tests/test_audio_music.gd",
]

const INTEGRATION_TESTS: Array[String] = []

const RUNTIME_HEAVY_TESTS: Array[String] = [
	"res://addons/local_agents/tests/test_llama_server_e2e.gd",
	"res://addons/local_agents/tests/test_agent_integration.gd",
	"res://addons/local_agents/tests/test_agent_runtime_heavy.gd",
]

const PERF_BENCHMARKS: Array[String] = []
