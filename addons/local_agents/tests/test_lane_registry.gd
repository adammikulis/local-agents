@tool
extends RefCounted
class_name LocalAgentTestLaneRegistry

# Test lanes for the LLM/agent/audio stack. The old homegrown ecosystem/settlement
# simulation + native voxel-op tests were removed with that stack, so these lanes now
# cover only the shipped subsystems (agent runtime, llama server, graph, audio).

const DETERMINISTIC_TESTS: Array[String] = [
	"res://addons/local_agents/tests/test_smoke_agent.gd",
	"res://addons/local_agents/tests/test_agent_utilities.gd",
	"res://addons/local_agents/tests/test_synth_dsp.gd",
	"res://addons/local_agents/tests/test_audio_music.gd",
	# The GDScript <-> native option contract (dead exports), and the node behaviours that shipped
	# with no tests. test_node_frames.gd runs run_frame_probe.gd in a child process for the half of
	# that behaviour which only exists across engine frames.
	"res://addons/local_agents/tests/test_native_option_contract.gd",
	"res://addons/local_agents/tests/test_node_behaviour.gd",
	"res://addons/local_agents/tests/test_node_frames.gd",
	# A LocalAgent with a backstory service attached actually remembers. Deterministic: it needs the
	# native NetworkGraph for the SQLite store, but no model and no llama-server, and it asserts on the
	# recalled TEXT rather than on any call reporting ok, because the first version of that wiring
	# returned ok everywhere and recalled nothing.
	"res://addons/local_agents/tests/test_agent_backstory.gd",
	# An animal can leave one group and join another, and the world writes both down as dated periods.
	# Same shape as the test above: it needs the native NetworkGraph and nothing else, and it asserts on
	# the membership history read back out of the store rather than on any call reporting ok.
	"res://addons/local_agents/tests/test_band_affiliation.gd",
	# Surface gravity does not depend on which body registered first. Needs no native extension, no model and
	# no GPU — two stub bodies in a bare tree settle it, which is the point: the bug it guards was invisible
	# to every windowed run, because the shipped boot order happens to avoid the window that triggers it.
	"res://addons/local_agents/tests/test_gravity_calibration.gd",
]

const INTEGRATION_TESTS: Array[String] = []

const RUNTIME_HEAVY_TESTS: Array[String] = [
	"res://addons/local_agents/tests/test_llama_server_e2e.gd",
	"res://addons/local_agents/tests/test_agent_integration.gd",
	"res://addons/local_agents/tests/test_agent_runtime_heavy.gd",
]

const PERF_BENCHMARKS: Array[String] = []
