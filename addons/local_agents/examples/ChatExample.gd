extends Node
class_name LocalAgentsChatExample

@onready var agent: LocalAgentsAgent = %Agent
@onready var chat_controller: LocalAgentsChatController = %ChatController
@onready var saved_controller: LocalAgentsSavedChatsController = %SavedChatsController
@onready var inference_config: LocalAgentsInferenceConfig = %InferenceConfig
@onready var model_config: LocalAgentsModelConfig = %ModelConfig

func _ready() -> void:
    chat_controller.prompt_input_received.connect(_on_prompt)
    agent.connect("model_output_received", Callable(self, "_on_agent_output"))
    agent.connect("message_emitted", Callable(self, "_on_agent_message"))
    if saved_controller:
        saved_controller.hide()

func _on_prompt(text: String) -> void:
    agent.think(text)

func _on_agent_output(text: String) -> void:
    chat_controller.append_output(text)

func _on_agent_message(role: String, content: String) -> void:
    chat_controller.append_output("[%s] %s" % [role, content])
