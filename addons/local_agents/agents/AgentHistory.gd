@tool
extends RefCounted
class_name LocalAgentAgentHistory

## LocalAgent's conversation record: appending messages, putting the agent's system prompt at the
## front, mirroring the whole conversation into the native AgentNode, and writing each message into
## the Memory Graph.
##
## The message Array itself deliberately stays on the node - `LocalAgent.history` is public and is read
## straight off the node by scenes and tests - so every method here is HANDED that Array and mutates it
## in place (Arrays are references in GDScript). The only state this file owns is the memory-graph
## cursor, which is what chains each message onto the one before it.
##
## Split out of Agent.gd so the node keeps the inference API and this file keeps the bookkeeping.
##
## (Explicit types only - project rule: no ':=' inferred typing.)

# Newest node written into the memory graph, so the next message can be chained onto it.
var _last_memory_node_id: int = -1


## Record a message the user sent: into the conversation, and into the graph.
func submit_user_message(history: Array, text: String, memory_graph: LocalAgentGraph) -> void:
    history.append({"role": "user", "content": text})
    record_in_memory_graph("user", text, memory_graph)


## Record a reply the model produced. Same two destinations as a user message.
func record_assistant_message(history: Array, text: String, memory_graph: LocalAgentGraph) -> void:
    history.append({"role": "assistant", "content": text})
    record_in_memory_graph("assistant", text, memory_graph)


## Put the agent's system_prompt at the front of its conversation.
##
## It has to go in the HISTORY, not in the options dictionary. The native runtime never reads
## options["system_prompt"] - it has a single `system_prompt_` member on the shared AgentRuntime
## singleton, which it injects only when the history contains no system message of its own
## (AgentRuntime.cpp:1643). So routing a per-agent prompt through set_system_prompt() would make
## every agent in the scene share one persona, and routing it through the options did nothing at all.
## A system message at index 0 is per-agent, and it also suppresses the runtime's generic default.
func apply_system_prompt(history: Array, system_prompt: String, agent_node: Object) -> void:
    var wanted: String = system_prompt.strip_edges()
    if wanted == "":
        return
    var first_is_system: bool = false
    if history.size() > 0 and history[0] is Dictionary:
        first_is_system = String((history[0] as Dictionary).get("role", "")) == "system"
    if first_is_system:
        var current: Dictionary = history[0]
        if String(current.get("content", "")) == wanted:
            return                      # already in place; do not churn the native history
        current["content"] = wanted
    else:
        history.insert(0, {"role": "system", "content": wanted})
    # The sync path reads the NATIVE node's own history (AgentNode::think uses get_history()), so the
    # GDScript-side edit has to be mirrored across or think() would not see it.
    sync_to_agent_node(history, agent_node)


## Rewrite the native node's history so it matches ours message for message.
func sync_to_agent_node(history: Array, agent_node: Object) -> void:
    if agent_node == null or not is_instance_valid(agent_node):
        return
    agent_node.clear_history()
    for entry_variant in history:
        if not (entry_variant is Dictionary):
            continue
        var entry: Dictionary = entry_variant
        agent_node.add_message(String(entry.get("role", "user")), String(entry.get("content", "")))


## Replace the conversation wholesale (LocalAgent.set_history), on both sides. Entries that are not
## dictionaries, or whose role or content is empty, are skipped rather than stored.
##
## Clears `history` again even though the caller already did: set_history() empties the node's own
## record BEFORE it checks that the runtime is available, so the two clears are not interchangeable
## and both have to stay.
func set_messages(history: Array, messages: Array, agent_node: Object) -> void:
    history.clear()
    agent_node.clear_history()
    for entry_variant in messages:
        if not (entry_variant is Dictionary):
            continue
        var entry: Dictionary = entry_variant
        var role_value: Variant = entry.get("role", "")
        var content_value: Variant = entry.get("content", "")
        var role: String = role_value if role_value is String else str(role_value)
        var content: String = content_value if content_value is String else str(content_value)
        if role.is_empty() or content.strip_edges().is_empty():
            continue
        history.append({
            "role": role,
            "content": content,
        })
        agent_node.add_message(role, content)


## Append one message to the Memory Graph, chained to the previous one by a "then" edge so the graph
## reads back as the conversation in order. Does nothing when no graph is assigned.
func record_in_memory_graph(role: String, content: String, memory_graph: LocalAgentGraph) -> void:
    if memory_graph == null or content.strip_edges() == "":
        return
    var entry: LocalAgentGraphNode = memory_graph.add_node(role, {"role": role, "content": content})
    if entry == null:
        return
    if _last_memory_node_id >= 0:
        memory_graph.add_edge(_last_memory_node_id, entry.id, "then")
    _last_memory_node_id = entry.id
