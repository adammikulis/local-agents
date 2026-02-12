extends CharacterBody3D
class_name LocalAgentsAgent3D

signal model_output_received(text)

@export var agent_path: NodePath = NodePath("Agent")
@export var chat_label_path: NodePath = NodePath("ChatLabel3D")
@export var animation_player_path: NodePath = NodePath("AnimationPlayer")

var agent: Node
var chat_label: Label3D
var animation_player: AnimationPlayer

func _ready() -> void:
    if agent_path != NodePath():
        agent = get_node_or_null(agent_path)
    if chat_label_path != NodePath():
        chat_label = get_node_or_null(chat_label_path)
    if animation_player_path != NodePath():
        animation_player = get_node_or_null(animation_player_path)
    if agent:
        agent.connect("model_output_received", Callable(self, "_on_agent_output"))

func think(prompt: String) -> void:
    if not agent:
        return
    if chat_label:
        chat_label.text = ""
    agent.think(prompt)

func _on_agent_output(text: String) -> void:
    if chat_label:
        chat_label.text += text
    if animation_player and animation_player.current_animation == "":
        animation_player.play("bobble")
    emit_signal("model_output_received", text)
