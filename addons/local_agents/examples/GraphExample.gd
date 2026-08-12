extends Node
class_name LAGraphExample


@export var graph: LocalAgentGraph = null

@onready var _output_label: Label = %OutputLabel


func _ready() -> void:
	_output_label.text = summary()


## The graph rendered as text. Public so a test or another panel can ask for the same readout.
func summary() -> String:
	if graph == null:
		return "GraphExample: assign a LocalAgentGraph to the Graph property in the inspector."

	var lines: PackedStringArray = PackedStringArray()
	lines.append("Nodes: %d | Edges: %d" % [graph.nodes.size(), graph.edges.size()])
	lines.append("")
	lines.append("Nodes:")
	for node in graph.nodes:
		lines.append("- %s (id %d)" % [node.name, node.id])
		for key in node.data.keys():
			lines.append("    %s: %s" % [key, node.data[key]])
	lines.append("")
	lines.append("Edges:")
	for edge in graph.edges:
		lines.append("- %s %s %s" % [_node_name(edge.source_id), edge.name, _node_name(edge.target_id)])
	return "\n".join(lines)


# Edges store ids, not names; a reader wants "Apple heals Food", not "2 heals 0".
func _node_name(node_id: int) -> String:
	var node: LocalAgentGraphNode = graph.get_node(node_id)
	if node == null:
		return "<missing id %d>" % node_id
	return node.name
