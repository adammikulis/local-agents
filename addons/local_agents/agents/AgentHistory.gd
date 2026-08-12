@tool
extends RefCounted
class_name LocalAgentAgentHistory


var _last_memory_node_id: int = -1


## Record a message the user sent: into the conversation, and into the graph.
func submit_user_message(history: Array, text: String, memory_graph: LocalAgentGraph) -> void:
    history.append({"role": "user", "content": text})
    record_in_memory_graph("user", text, memory_graph)


## Record a reply the model produced. Same two destinations as a user message.
func record_assistant_message(history: Array, text: String, memory_graph: LocalAgentGraph) -> void:
    history.append({"role": "assistant", "content": text})
    record_in_memory_graph("assistant", text, memory_graph)


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
