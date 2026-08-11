@icon("res://addons/local_agents/icons/local_agent_3d.svg")
extends CharacterBody3D
class_name LocalAgent3D

## A LocalAgent with a body: a character that thinks, then says the answer on a Label3D above its
## head and plays a talk animation while it does.
##
## The three node paths below are how it finds its own parts. They default to the names used in
## Agent3D.tscn, so an instance of that scene needs no configuration at all. Re-point them if you
## build your own character around a LocalAgent.
##
## `think()` / `think_async()` / `speak()` forward to the LocalAgent, so a caller drives the character
## directly instead of reaching through `.get("agent")` or `Engine.get_singleton("AgentRuntime")`
## reflection to find the runtime.
##
## (Explicit types only. Project rule: no ':=' inferred typing.)

## Re-emitted from the inner LocalAgent whenever the model produces text, after it has been written
## onto the Label3D.
signal model_output_received(text: String)

@export_group("Wiring")

## The LocalAgent node that does the thinking. Without it the character is inert.
@export_node_path("LocalAgent") var agent_path: NodePath = NodePath("Agent")

## Label3D the reply is typed onto, usually floating above the head. Leave empty for a silent
## character whose replies you render yourself from `model_output_received`.
@export_node_path("Label3D") var chat_label_path: NodePath = NodePath("ChatLabel3D")

## AnimationPlayer holding the talk animation. Leave empty for a character that does not move
## when it speaks.
@export_node_path("AnimationPlayer") var animation_player_path: NodePath = NodePath("AnimationPlayer")

@export_group("Animation")

## Animation played when a reply arrives, if the AnimationPlayer is idle and actually has a clip by
## this name. Nothing plays when it does not, so a rig without a talk clip is not an error.
@export var animation_name: StringName = &"bobble"

var agent: LocalAgent
var chat_label: Label3D
var animation_player: AnimationPlayer

func _ready() -> void:
    if agent_path != NodePath():
        agent = get_node_or_null(agent_path) as LocalAgent
    if chat_label_path != NodePath():
        chat_label = get_node_or_null(chat_label_path) as Label3D
    if animation_player_path != NodePath():
        animation_player = get_node_or_null(animation_player_path) as AnimationPlayer
    if agent != null and not agent.model_output_received.is_connected(_on_agent_output):
        agent.model_output_received.connect(_on_agent_output)

## Ask the model, blocking the frame until it answers, and return the runtime's result Dictionary
## ({"ok": bool, "text": String, ...}). Clears the Label3D first so the old reply does not linger.
func think(prompt: String, extra_opts: Dictionary = {}) -> Dictionary:
    if agent == null:
        return {"ok": false, "error": "agent_unavailable"}
    if chat_label != null:
        chat_label.text = ""
    return agent.think(prompt, extra_opts)

## Ask the model without blocking the frame. Returns true when the job started; the reply arrives on
## `model_output_received` (and on the agent's own `think_completed`).
func think_async(prompt: String, extra_opts: Dictionary = {}) -> bool:
    if agent == null:
        return false
    if chat_label != null:
        chat_label.text = ""
    return agent.think_async(prompt, extra_opts)

## Speak `text` aloud through the agent's voice, without asking the model anything.
func speak(text: String, opts: Dictionary = {}) -> bool:
    if agent == null:
        return false
    return agent.speak(text, opts)

func _on_agent_output(text: String) -> void:
    if chat_label != null:
        chat_label.text += text
    if animation_player != null and animation_player.current_animation == "" and animation_player.has_animation(animation_name):
        animation_player.play(animation_name)
    model_output_received.emit(text)
