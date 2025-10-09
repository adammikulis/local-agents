extends Node
class_name LocalAgentsGraphExample

@export var GraphResource: Resource

func _ready() -> void:
    if GraphResource is LocalAgentsGraph:
        var graph: LocalAgentsGraph = GraphResource
        var food_node = graph.add_node("Food", {"nutrition": 5})
        var poison_node = graph.add_node("Poison", {"toxicity": 10})
        var apple_node = graph.add_node("Apple", {"type": "fruit"})
        var berry_node = graph.add_node("Oozing Berry", {"type": "berry"})
        graph.add_edge(apple_node.id, food_node.id, "heals")
        graph.add_edge(berry_node.id, poison_node.id, "hurts")
        _print_summary(graph)

func _print_summary(graph: LocalAgentsGraph) -> void:
    for node in graph.nodes:
        print("Node %s (%s)" % [node.id, node.name])
        for key in node.data.keys():
            print("  %s: %s" % [key, node.data[key]])
    for edge in graph.edges:
        print("Edge %s: %s -> %s (%s)" % [edge.id, edge.source_id, edge.target_id, edge.name])
