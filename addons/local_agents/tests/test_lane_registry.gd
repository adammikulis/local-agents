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
	# An in-place transfer (same cell array as source and destination) coalesces without duplicating its
	# cells. Pure GDScript against the queue object: no device, no field, no world. The bug it guards made
	# every merged mineral transfer vanish into a size check inside move_field_sparse, reporting nothing.
	"res://addons/local_agents/tests/test_inject_queue_alias.gd",
	# Weathering does not get faster as the planet gets colder. Pure GDScript over the LIVE records: it walks
	# LAGeoRecords across a temperature sweep using the kernel's own rate arithmetic and asserts the SHAPE of
	# each mechanism — chemical dissolution monotone in T with a ~2.2x Q10, frost shattering exactly zero above
	# the real freezing point and plateauing rather than climbing into the cold. It exists because the record
	# it replaced was a constant fitted to "the sim's actual range" with the temperature sign backwards, and
	# nothing in the suite could have caught that.
	"res://addons/local_agents/tests/test_weathering_rate_law.gd",
	# Combustion is chemistry and has no ignition temperature. Pure GDScript over the LIVE record: it walks
	# LACombustionRecords across a temperature sweep with the kernel's own arithmetic and asserts that the rate
	# is smooth and positive everywhere (no threshold), spans twenty orders of magnitude (a runaway), balances
	# CH2O + O2 -> CO2 + H2O + N in MOLES, stops below the limiting oxygen concentration, and warms a damp cell
	# a hundredfold less than a dry one through the heat capacity alone. It exists because combustion is
	# unreachable in a run — every arm reports `fires` 0 — so no SIM_REPORT can settle any of this.
	"res://addons/local_agents/tests/test_combustion_rate_law.gd",
]

const INTEGRATION_TESTS: Array[String] = []

const RUNTIME_HEAVY_TESTS: Array[String] = [
	"res://addons/local_agents/tests/test_llama_server_e2e.gd",
	"res://addons/local_agents/tests/test_agent_integration.gd",
	"res://addons/local_agents/tests/test_agent_runtime_heavy.gd",
]

const PERF_BENCHMARKS: Array[String] = []
