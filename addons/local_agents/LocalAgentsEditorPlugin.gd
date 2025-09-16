@tool
extends EditorPlugin

var agent_script := load("res://addons/local_agents/agents/Agent.gd")
var agent_icon := load("res://addons/local_agents/assets/logos/brain_pink.png")

func _enter_tree() -> void:
    add_custom_type("Agent", "Node", agent_script, agent_icon)

func _exit_tree() -> void:
    remove_custom_type("Agent")
