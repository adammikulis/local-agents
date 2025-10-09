extends Resource
class_name LocalAgentsGraph

@export var nodes: Array[LocalAgentsGraphNode] = []
@export var edges: Array[LocalAgentsGraphEdge] = []

var _next_node_id := 0
var _next_edge_id := 0

func ensure_id_counters() -> void:
    var max_node_id := -1
    for node in nodes:
        max_node_id = max(max_node_id, node.id)
    _next_node_id = max_node_id + 1

    var max_edge_id := -1
    for edge in edges:
        max_edge_id = max(max_edge_id, edge.id)
    _next_edge_id = max_edge_id + 1

func add_node(name: String = "", data: Dictionary = {}) -> LocalAgentsGraphNode:
    ensure_id_counters()
    var node := LocalAgentsGraphNode.new(_next_node_id, name, data)
    nodes.append(node)
    _next_node_id += 1
    return node

func remove_node(node_id: int) -> bool:
    var node := get_node(node_id)
    if node == null:
        return false
    nodes.erase(node)
    var to_remove: Array = []
    for edge in edges:
        if edge.source_id == node_id or edge.target_id == node_id:
            to_remove.append(edge)
    for edge in to_remove:
        edges.erase(edge)
    return true

func add_edge(source_id: int, target_id: int, name: String = "", weight: float = 1.0, data: Dictionary = {}, is_bidirectional: bool = false) -> LocalAgentsGraphEdge:
    ensure_id_counters()
    var source_node := get_node(source_id)
    var target_node := get_node(target_id)
    if source_node == null or target_node == null:
        push_error("Source or target node does not exist")
        return null
    var edge := LocalAgentsGraphEdge.new(_next_edge_id, source_id, target_id, name, weight, data)
    edges.append(edge)
    _next_edge_id += 1
    if is_bidirectional:
        var reverse := LocalAgentsGraphEdge.new(_next_edge_id, target_id, source_id, name, weight, data)
        edges.append(reverse)
        _next_edge_id += 1
    return edge

func remove_edge(edge_id: int) -> bool:
    var edge := get_edge(edge_id)
    if edge == null:
        return false
    edges.erase(edge)
    return true

func get_node(node_id: int) -> LocalAgentsGraphNode:
    for node in nodes:
        if node.id == node_id:
            return node
    return null

func get_edge(edge_id: int) -> LocalAgentsGraphEdge:
    for edge in edges:
        if edge.id == edge_id:
            return edge
    return null

func get_edges() -> Array[LocalAgentsGraphEdge]:
    return edges

func update_edge_weight(edge_id: int, amount: float) -> void:
    var edge := get_edge(edge_id)
    if edge:
        edge.update_weight(amount)

func update_all_edge_weights(amount: float) -> void:
    for edge in edges:
        edge.update_weight(amount)
