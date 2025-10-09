extends Node
class_name MindAgent

signal response_ready(response)
signal error_received(message)

@export var prompt_prefix: String = ""
@export var system_prompt: String = "You are a helpful in-game assistant."

var _manager: LocalAgentManager

func _ready() -> void:
    _manager = get_node_or_null("/root/LocalAgentManager")
    if _manager:
        _manager.connect("inference_finished", _on_inference_finished)
        _manager.connect("inference_failed", _on_inference_failed)
    else:
        push_warning("LocalAgentManager autoload is not present.")

func send_message(message: String, max_tokens: int = 128, temperature: float = 0.7) -> void:
    if not _manager:
        emit_signal("error_received", "LocalAgentManager is unavailable")
        return
    var full_prompt := message if prompt_prefix.is_empty() else prompt_prefix + "\n" + message
    _manager.generate_response(full_prompt, max_tokens, temperature, system_prompt)

func _on_inference_finished(response: String) -> void:
    emit_signal("response_ready", response)

func _on_inference_failed(message: String) -> void:
    emit_signal("error_received", message)
