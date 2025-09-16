extends Control
class_name LocalAgentsChatController

signal prompt_input_received(text)

@onready var input_line: LineEdit = %ModelInputLineEdit
@onready var output_label: RichTextLabel = %ModelOutputRichTextLabel

func _ready() -> void:
    input_line.text_submitted.connect(_on_input_submitted)

func _on_input_submitted(text: String) -> void:
    if text.strip_edges() == "":
        return
    output_label.text += text + "\n"
    input_line.text = ""
    emit_signal("prompt_input_received", text)

func append_output(text: String) -> void:
    output_label.text += text + "\n"
