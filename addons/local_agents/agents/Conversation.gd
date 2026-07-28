@tool
extends Node
class_name LocalAgentConversation

## N LocalAgent nodes taking turns talking to each other — the addon's plural name made real.
##
## Drop this node in, drag your agents into `agents`, type a `topic`, and press play. Each utterance
## is appended to the transcript and recorded as a node in `memory_graph`, chained to the previous one
## by an edge named `edge_name`; that growing graph IS the conversation's memory — structured state
## you can query, save as a `.tres`, or draw.
##
## This was 140 lines living inside AgentConversationDemo, hard-coded to exactly two agents called Ada
## and Ben with their personas as constants. Personas are not a property here on purpose: give each
## agent its own voice through its LocalAgentModelProfile system prompt, which is where model
## behaviour already belongs.
##
## With no usable model the node speaks `canned_lines` instead, so the turn-taking and the memory
## graph still demonstrate themselves on a machine with nothing installed.
##
## Generation runs through `think_async`, so a turn never blocks the frame; the line arrives on
## `turn_taken` when the model is done.
##
## (Explicit types only — project rule: no ':=' inferred typing.)

## Emitted once per completed utterance, after it has been recorded in the transcript and the graph.
signal turn_taken(speaker: String, text: String)
## Emitted when `max_turns` has been reached. Never emitted when `max_turns` is 0.
signal conversation_finished()

const Status: GDScript = preload("res://addons/local_agents/runtime/AgentStatus.gd")

# A plain Array literal, NOT PackedStringArray([...]): a const cannot hold a constructor call.
const DEFAULT_CANNED: Array = [
    "Let's start with the cheapest thing that could possibly work.",
    "Cheap is fine until it breaks. What happens then?",
    "Then we replace it, having learned what we actually needed.",
    "Agreed — start small, keep the receipts.",
]

@export_group("Cast")

## The agents that take turns, in speaking order. Leave empty to run the canned exchange instead.
@export var agents: Array[LocalAgent] = []

## Display names, one per agent, in the same order. Leave empty to use each agent node's own name.
@export var speaker_names: PackedStringArray = PackedStringArray()

@export_group("Conversation")

## What they are talking about. Sent with every prompt, so keep it to a sentence.
@export_multiline var topic: String = ""

## Stop after this many utterances and emit conversation_finished. 0 = unlimited.
@export_range(0, 500, 1, "suffix:turns") var max_turns: int = 0

## How many previous utterances are quoted back to the speaker as context. Higher means a more
## coherent conversation and a longer, slower prompt.
@export_range(1, 40, 1, "suffix:turns") var context_turns: int = 6

@export_group("Pacing")

## Take a turn automatically every `turn_interval` seconds. Off means you call next_turn() yourself
## (from a button, a timer, or a trigger volume).
@export var auto_advance: bool = false:
    set(value):
        auto_advance = value
        _sync_timer()

## Seconds between automatic turns. Only used when Auto Advance is on. A turn that is still waiting
## on the model is skipped rather than queued.
@export_range(0.0, 60.0, 0.25, "suffix:s") var turn_interval: float = 2.0:
    set(value):
        turn_interval = value
        _sync_timer()

@export_group("Memory")

## Graph that records the conversation: one node per utterance, chained in order. Leave empty and one
## is created when the scene runs, so the memory exists either way; assign a saved `.tres` to keep it.
@export var memory_graph: LocalAgentGraph

## Name given to the edge joining each utterance to the one before it.
@export var edge_name: String = "then"

@export_group("Fallback")

## Used verbatim, in order, when no model is available, so the loop still demonstrates itself.
## Leave empty to use a short built-in exchange.
@export var canned_lines: PackedStringArray = PackedStringArray()

var _turn: int = 0
var _lines: PackedStringArray = PackedStringArray()
var _last_node_id: int = -1
var _busy: bool = false
var _finished: bool = false
var _pending_speaker: int = -1
var _timer: Timer = null
var _connected_agents: Dictionary = {}


func _ready() -> void:
    if Engine.is_editor_hint():
        update_configuration_warnings()
        return
    if memory_graph == null:
        memory_graph = LocalAgentGraph.new()
    _timer = Timer.new()
    _timer.name = "TurnTimer"
    _timer.one_shot = false
    _timer.timeout.connect(_on_turn_timer)
    add_child(_timer)
    _sync_timer()


## Take the next turn. Returns true when a turn was started (or, on the canned path, completed).
## False means the conversation is finished, a turn is still in flight, or there is nobody to speak.
func next_turn() -> bool:
    if Engine.is_editor_hint() or _finished or _busy:
        return false
    var count: int = _speaker_count()
    if count == 0:
        return false
    if max_turns > 0 and _turn >= max_turns:
        _finish()
        return false

    var index: int = _turn % count
    var speaker: String = _speaker_name(index)
    var agent: LocalAgent = _agent_for(index)
    if agent == null or not is_using_model():
        _record(speaker, _canned_line())
        return true

    _busy = true
    _pending_speaker = index
    if not _connected_agents.has(agent.get_instance_id()):
        agent.think_completed.connect(_on_think_completed)
        _connected_agents[agent.get_instance_id()] = true
    if not agent.think_async(_build_prompt(speaker)):
        # think_async only returns false after deferring a failure result, or when that agent is
        # already generating for someone else — either way a think_completed reaches us and clears
        # the busy flag, so nothing is stranded here.
        pass
    return true


## Forget the transcript, the turn counter and the memory graph, and allow the conversation to run
## again from the top. The graph resource is emptied in place, not replaced.
func reset() -> void:
    _turn = 0
    _lines = PackedStringArray()
    _last_node_id = -1
    _busy = false
    _finished = false
    _pending_speaker = -1
    if memory_graph != null:
        memory_graph.nodes.clear()
        memory_graph.edges.clear()
        memory_graph.ensure_id_counters()


## Every utterance so far, as "Speaker: text" lines.
func transcript() -> PackedStringArray:
    return _lines.duplicate()


## True when a real model will produce the next line, false when `canned_lines` will.
## The first call can pause briefly: a model that is present but not loaded is loaded here.
func is_using_model() -> bool:
    if _valid_agents().is_empty():
        return false
    var blockers: PackedStringArray = Status.check()["blockers"]
    if blockers.is_empty():
        return true
    if blockers.size() == 1 and String(blockers[0]) == Status.BLOCK_MODEL_NOT_LOADED:
        return Status.ensure_model_loaded()
    return false


## How many utterances have been recorded.
func turns_taken() -> int:
    return _turn


func _get_configuration_warnings() -> PackedStringArray:
    var out: PackedStringArray = PackedStringArray()
    if agents.is_empty():
        out.append("No agents assigned, so this node will speak Canned Lines instead of thinking. Drag one or more LocalAgent nodes into Agents.")
    else:
        out.append_array(Status.warnings_for({"extension": true, "autoload": true, "model": true}))
    if not speaker_names.is_empty() and not agents.is_empty() and speaker_names.size() != agents.size():
        out.append("Speaker Names has %d entries but there are %d agents; the extras are ignored." % [speaker_names.size(), agents.size()])
    return out


func _on_turn_timer() -> void:
    next_turn()


func _on_think_completed(result: Dictionary) -> void:
    if not _busy or _pending_speaker < 0:
        return   # a reply for some other driver of this same agent
    var speaker: String = _speaker_name(_pending_speaker)
    _busy = false
    _pending_speaker = -1
    var text: String = String(result.get("text", "")).strip_edges()
    if not bool(result.get("ok", true)):
        text = "(generation failed: %s)" % String(result.get("error", "unknown"))
    elif text == "":
        text = "(no reply)"
    _record(speaker, text)


func _build_prompt(speaker: String) -> String:
    var parts: PackedStringArray = PackedStringArray()
    if topic.strip_edges() != "":
        parts.append("Topic: %s" % topic.strip_edges())
    if not _lines.is_empty():
        parts.append("Conversation so far:\n%s" % "\n".join(_recent_lines()))
    parts.append("Reply as %s in one short sentence." % speaker)
    return "\n".join(parts)


func _recent_lines() -> PackedStringArray:
    var start: int = maxi(0, _lines.size() - context_turns)
    return _lines.slice(start)


func _record(speaker: String, text: String) -> void:
    _lines.append("%s: %s" % [speaker, text])
    if memory_graph != null:
        var node: LocalAgentGraphNode = memory_graph.add_node(speaker, {"turn": _turn, "said": text})
        if node != null:
            if _last_node_id != -1:
                memory_graph.add_edge(_last_node_id, node.id, edge_name)
            _last_node_id = node.id
    _turn += 1
    turn_taken.emit(speaker, text)
    if max_turns > 0 and _turn >= max_turns:
        _finish()


func _finish() -> void:
    if _finished:
        return
    _finished = true
    if _timer != null:
        _timer.stop()
    conversation_finished.emit()


func _canned_line() -> String:
    var source: PackedStringArray = canned_lines
    if source.is_empty():
        source = PackedStringArray(DEFAULT_CANNED)
    return String(source[_turn % source.size()])


func _speaker_count() -> int:
    if not agents.is_empty():
        return agents.size()
    if not speaker_names.is_empty():
        return speaker_names.size()
    return 2   # canned demo with nothing configured: two nameless speakers


func _speaker_name(index: int) -> String:
    if index >= 0 and index < speaker_names.size():
        var explicit: String = String(speaker_names[index]).strip_edges()
        if explicit != "":
            return explicit
    var agent: LocalAgent = _agent_for(index)
    if agent != null:
        return String(agent.name)
    return "Speaker %d" % (index + 1)


func _agent_for(index: int) -> LocalAgent:
    if index < 0 or index >= agents.size():
        return null
    var agent: LocalAgent = agents[index]
    if agent == null or not is_instance_valid(agent):
        return null
    return agent


func _valid_agents() -> Array[LocalAgent]:
    var out: Array[LocalAgent] = []
    for entry in agents:
        if entry != null and is_instance_valid(entry):
            out.append(entry)
    return out


# Property setters fire during scene load, long before _ready builds the timer, so this is a no-op
# until there is something to configure.
func _sync_timer() -> void:
    if _timer == null:
        return
    _timer.wait_time = maxf(0.05, turn_interval)
    if auto_advance and not _finished:
        _timer.start()
    else:
        _timer.stop()
