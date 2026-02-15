extends Node
class_name LocalAgentsGraphExample

@export var GraphResource: Resource
@onready var _output_label: Label = %OutputLabel

func _ready() -> void:
    if not (GraphResource is LocalAgentsGraph):
        _output_label.text = "GraphExample: assign a LocalAgentsGraph resource."
        return
    var graph: LocalAgentsGraph = GraphResource
    var food_node: Dictionary = _ensure_node(graph, "Food", {"nutrition": 5})
    var poison_node: Dictionary = _ensure_node(graph, "Poison", {"toxicity": 10})
    var apple_node: Dictionary = _ensure_node(graph, "Apple", {"type": "fruit"})
    var berry_node: Dictionary = _ensure_node(graph, "Oozing Berry", {"type": "berry"})
    _ensure_edge(graph, apple_node.id, food_node.id, "heals")
    _ensure_edge(graph, berry_node.id, poison_node.id, "hurts")
    _render_summary(graph)

func _render_summary(graph: LocalAgentsGraph) -> void:
    var lines: PackedStringArray = []
    lines.append("LocalAgentsGraph demo ready")
    lines.append("Nodes: %d | Edges: %d" % [graph.nodes.size(), graph.edges.size()])
    lines.append("")
    lines.append("Node samples:")
    for node in graph.nodes:
        lines.append("- %s (%d)" % [node.name, node.id])
        for key in node.data.keys():
            lines.append("  %s: %s" % [key, node.data[key]])
    lines.append("")
    lines.append("Edges:")
    for edge in graph.edges:
        lines.append("- %s: %s -> %s (%s)" % [edge.id, edge.source_id, edge.target_id, edge.name])
    _output_label.text = "\n".join(lines)

func _ensure_node(graph: LocalAgentsGraph, name: String, data: Dictionary):
    for existing in graph.nodes:
        if existing.name == name:
            return existing
    return graph.add_node(name, data)

func _ensure_edge(graph: LocalAgentsGraph, source_id: int, target_id: int, edge_name: String) -> void:
    for edge in graph.edges:
        if edge.source_id == source_id and edge.target_id == target_id and edge.name == edge_name:
            return
    graph.add_edge(source_id, target_id, edge_name)
