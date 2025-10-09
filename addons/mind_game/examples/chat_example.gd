extends Control

@onready var prompt_input: LineEdit = %PromptInput
@onready var output_view: RichTextLabel = %OutputView
@onready var status_label: Label = %StatusLabel
@onready var agent: MindAgent = $MindAgent

func _ready() -> void:
    if not agent:
        push_warning("MindAgent node is missing from the scene")
        return
    agent.connect("response_ready", _on_response_ready)
    agent.connect("error_received", _on_error_received)

func _on_send_button_pressed() -> void:
    status_label.text = "Running inference..."
    output_view.text = ""
    var prompt := prompt_input.text.strip_edges()
    agent.send_message(prompt)

func _on_response_ready(response: String) -> void:
    status_label.text = "Response received"
    output_view.text = response

func _on_error_received(message: String) -> void:
    status_label.text = message
