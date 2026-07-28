extends Node

## This demo's own presentation, and nothing else.
##
## The cast, the topic, the prompting, the turn-taking and the memory graph all live on the
## LocalAgentConversation node in AgentConversationDemo.tscn — select it in the editor to change
## any of them. The Next button calls its next_turn() straight from the Node dock, with no code.
##
## What is left here is what this scene chose to SHOW: painting each utterance into a transcript
## and reporting how large the memory has grown. Your game would draw it differently.
##
## (Explicit types only — project rule: no ':=' inferred typing.)

@onready var _conversation: LocalAgentConversation = %Conversation
@onready var _transcript: RichTextLabel = %Transcript
@onready var _memory_label: Label = %MemoryLabel


# Connected in the scene to Conversation.turn_taken.
func _on_conversation_turn_taken(speaker: String, text: String) -> void:
	# A model is free to answer with a stray "[", which RichTextLabel would otherwise eat as markup.
	_transcript.append_text("[b]%s[/b] %s\n" % [speaker, text.replace("[", "[lb]")])
	_refresh_memory()


# Connected in the scene to ResetButton.pressed. reset() empties the graph in place; the transcript
# is this scene's own, so it clears that too.
func _on_reset_button_pressed() -> void:
	_conversation.reset()
	_transcript.clear()
	_refresh_memory()


func _refresh_memory() -> void:
	var graph: LocalAgentGraph = _conversation.memory_graph
	if graph == null:
		return
	_memory_label.text = "Memory graph: %d nodes, %d edges" % [graph.nodes.size(), graph.edges.size()]
