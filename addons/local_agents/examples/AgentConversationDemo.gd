extends Node


@onready var _conversation: LocalAgentConversation = %Conversation
@onready var _transcript: RichTextLabel = %Transcript
@onready var _memory_label: Label = %MemoryLabel
@onready var _last_recorded_label: Label = %LastRecordedLabel


func _ready() -> void:
	_seed_transcript()
	_refresh_memory()


# Connected in the scene to Conversation.turn_taken.
func _on_conversation_turn_taken(speaker: String, text: String) -> void:
	# A model is free to answer with a stray "[", which RichTextLabel would otherwise eat as markup.
	_transcript.append_text("[b]%s[/b] %s\n" % [speaker, text.replace("[", "[lb]")])
	_refresh_memory()


func _on_reset_button_pressed() -> void:
	_conversation.reset()
	_transcript.clear()
	_seed_transcript()
	_refresh_memory()


# The transcript opens with what they are talking about. An empty topic gets no line rather than a
# bare "Topic:".
func _seed_transcript() -> void:
	var topic: String = _conversation.topic.strip_edges()
	if topic == "":
		return
	_transcript.append_text("[b]Topic:[/b] %s\n" % topic.replace("[", "[lb]"))


func _refresh_memory() -> void:
	var graph: LocalAgentGraph = _conversation.memory_graph
	if graph != null:
		_memory_label.text = "Memory graph: %d nodes, %d edges" % [graph.nodes.size(), graph.edges.size()]
	var lines: PackedStringArray = _conversation.transcript()
	var last: String = "-"
	if not lines.is_empty():
		last = String(lines[lines.size() - 1])
	_last_recorded_label.text = "Last recorded: %s" % last
