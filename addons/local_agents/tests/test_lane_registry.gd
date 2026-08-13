@tool
extends RefCounted
class_name LocalAgentTestLaneRegistry


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
	"res://addons/local_agents/tests/test_agent_backstory.gd",
	"res://addons/local_agents/tests/test_band_affiliation.gd",
	"res://addons/local_agents/tests/test_inject_queue_alias.gd",
	"res://addons/local_agents/tests/test_weathering_rate_law.gd",
	"res://addons/local_agents/tests/test_combustion_rate_law.gd",
	"res://addons/local_agents/tests/test_reaction_direction.gd",
	"res://addons/local_agents/tests/test_enthalpy_roundtrip.gd",
	"res://addons/local_agents/tests/test_latent_plateau.gd",
	"res://addons/local_agents/tests/test_mixture_enthalpy.gd",
	"res://addons/local_agents/tests/test_density_eos.gd",
	"res://addons/local_agents/tests/test_conversation_store.gd",
]

const INTEGRATION_TESTS: Array[String] = []

const RUNTIME_HEAVY_TESTS: Array[String] = [
	"res://addons/local_agents/tests/test_llama_server_e2e.gd",
	"res://addons/local_agents/tests/test_agent_integration.gd",
	"res://addons/local_agents/tests/test_agent_runtime_heavy.gd",
]

const PERF_BENCHMARKS: Array[String] = []


## The full script path in `lane` that `token` names, by exact path or by file name; "" if none does.
static func resolve(token: String, lane: Array) -> String:
	if lane.has(token):
		return token
	for script_path in lane:
		if script_path.ends_with("/%s" % token) or script_path.get_file() == token:
			return script_path
	return ""
