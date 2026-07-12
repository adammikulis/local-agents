extends Node
class_name LocalAgentConversationDemo

## Ladder rung 3: cognition + memory. Two LocalAgent nodes take turns
## talking to each other. Each utterance is recorded as a node in a shared
## LocalAgentGraph (the same graph resource shown on its own in GraphExample),
## chained by "then" edges. That growing graph is the conversation's memory:
## structured, queryable state that accumulates as the agents think.
##
## Press "Next turn" to advance one utterance at a time (think() blocks, so we
## keep it human-paced instead of spinning a loop). With no model or runtime the
## demo falls back to a short canned exchange so the turn-taking + memory graph
## are still visible.

@onready var agent_a: LocalAgent = %AgentA
@onready var agent_b: LocalAgent = %AgentB
@onready var status_label: Label = %StatusLabel
@onready var transcript_label: RichTextLabel = %TranscriptLabel
@onready var memory_label: Label = %MemoryLabel
@onready var next_button: Button = %NextButton
@onready var reset_button: Button = %ResetButton

const ExtensionLoader = preload("res://addons/local_agents/runtime/LocalAgentsExtensionLoader.gd")
const RuntimePaths = preload("res://addons/local_agents/runtime/RuntimePaths.gd")

const PERSONA_A: String = "You are Ada, a curious optimist planning a small garden."
const PERSONA_B: String = "You are Ben, a practical skeptic who worries about the budget."
const TOPIC: String = "What should we plant first in the shared garden?"

# Canned lines used only when there is no model, so the loop still demonstrates.
const CANNED: Array = [
	"Ada: Let's start with tomatoes, they give the most for a first season.",
	"Ben: Tomatoes need cages and daily water though. Can we afford that?",
	"Ada: Fair. Herbs are cheaper and hard to kill, so maybe basil and mint first.",
	"Ben: Agreed, herbs it is. We can graduate to tomatoes once we know we can keep up.",
]

var _graph: LocalAgentGraph
var _turn: int = 0
var _last_node_id: int = -1
var _transcript: Array = []
var _busy: bool = false
var _use_model: bool = false

func _ready() -> void:
	_graph = LocalAgentGraph.new()
	next_button.pressed.connect(_on_next_turn)
	reset_button.pressed.connect(_reset)
	_reset()

func _reset() -> void:
	_graph = LocalAgentGraph.new()
	_turn = 0
	_last_node_id = -1
	_transcript.clear()
	transcript_label.clear()
	transcript_label.append_text("Topic: %s\n" % TOPIC)
	_refresh_status()
	_update_memory()

func _on_next_turn() -> void:
	if _busy:
		return
	_busy = true
	next_button.disabled = true
	var speaker_name: String = "Ada" if _turn % 2 == 0 else "Ben"
	var line: String = _produce_line(speaker_name)
	_record(speaker_name, line)
	_turn += 1
	_busy = false
	next_button.disabled = false
	_refresh_status()

# Ask the current speaker's agent for its next line, or fall back to canned text.
func _produce_line(speaker_name: String) -> String:
	if not _use_model:
		var canned: String = String(CANNED[_turn % CANNED.size()])
		return canned.split(": ", true, 1)[-1]
	var agent: LocalAgent = agent_a if speaker_name == "Ada" else agent_b
	var persona: String = PERSONA_A if speaker_name == "Ada" else PERSONA_B
	var prompt: String = "%s\nTopic: %s\nConversation so far:\n%s\nReply as %s in one short sentence." % [
		persona, TOPIC, _recent_transcript(), speaker_name,
	]
	var result: Dictionary = agent.think(prompt)
	if not bool(result.get("ok", true)):
		return "(generation failed: %s)" % String(result.get("error", "unknown"))
	var text: String = String(result.get("text", "")).strip_edges()
	if text.is_empty():
		return "(no reply)"
	return text

func _recent_transcript() -> String:
	var recent: Array = _transcript.slice(max(0, _transcript.size() - 6), _transcript.size())
	return "\n".join(PackedStringArray(recent))

# Record the utterance both in the visible transcript and as a memory-graph node
# chained to the previous one. Node count / edge count is the memory size.
func _record(speaker_name: String, line: String) -> void:
	var entry: String = "%s: %s" % [speaker_name, line]
	_transcript.append(entry)
	transcript_label.append_text(entry + "\n")
	var node: LocalAgentGraphNode = _graph.add_node(speaker_name, {"turn": _turn, "said": line})
	if _last_node_id != -1:
		_graph.add_edge(_last_node_id, node.id, "then")
	_last_node_id = node.id
	_update_memory()

func _update_memory() -> void:
	var last_said: String = "-"
	if not _transcript.is_empty():
		last_said = String(_transcript[-1])
	memory_label.text = "Memory graph: %d nodes, %d edges\nLast recorded: %s" % [
		_graph.nodes.size(), _graph.edges.size(), last_said,
	]

func _refresh_status() -> void:
	_use_model = _runtime_ready()
	if not ExtensionLoader.ensure_initialized():
		var runtime_error: String = ExtensionLoader.get_error()
		if runtime_error.is_empty():
			runtime_error = "unavailable"
		status_label.text = "No native runtime (%s). Showing a canned exchange; the turn-taking and memory graph are real." % runtime_error
		return
	var default_model: String = RuntimePaths.resolve_default_model()
	if default_model.is_empty():
		status_label.text = "No GGUF model found. Showing a canned exchange; add a model to let Ada and Ben think for themselves."
		return
	status_label.text = "Ready: %s. Press Next turn to let Ada and Ben converse." % default_model.get_file()

func _runtime_ready() -> bool:
	if not ExtensionLoader.ensure_initialized():
		return false
	if agent_a.agent_node == null:
		return false
	var model_path: String = String(agent_a.agent_node.get_default_model_path()).strip_edges()
	if model_path.is_empty():
		return false
	if agent_a.agent_node.has_method("is_model_loaded") and bool(agent_a.agent_node.call("is_model_loaded")):
		return true
	return bool(agent_a.agent_node.load_model(model_path, {}))
