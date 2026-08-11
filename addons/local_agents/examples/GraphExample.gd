extends Node
class_name LAGraphExample

## Prints the contents of a LocalAgentGraph into a Label, so you can see what a graph resource holds.
##
## The graph itself is not built here. It is a sub-resource of GraphExample.tscn: select the root
## node, open Graph in the inspector, and the four nodes and two edges are right there to edit. That
## is the point. A graph is data you author, not code you run.
##
## Nothing in this file writes to a resource — res:// is read-only in an exported build.
##
## Needs no model and no runtime, because a graph is plain data.
##
## (Explicit types only. The project rule bans ':=' inferred typing.)

## The graph to display. Authored as a sub-resource inside this scene. Point it at a .tres instead if
## you want one graph shared between scenes.
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
