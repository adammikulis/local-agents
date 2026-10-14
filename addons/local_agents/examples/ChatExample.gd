extends Node


@onready var chat_controller: LAChatController = %ChatController
@onready var inference_config: LAInferenceConfig = %InferenceConfig
@onready var model_config: LAModelConfig = %ModelConfig
@onready var download_hint_label: RichTextLabel = %DownloadHintLabel


# Connected in the scene to HomeButton.pressed.
func _on_home_button_pressed() -> void:
    _show_configuration("model")



# Connected in the scene to ChatButton.pressed. This is the state the scene is saved in.
func _on_chat_button_pressed() -> void:
    $HBoxContainer/ChatVBoxContainer.visible = true
    chat_controller.visible = true
    model_config.visible = false
    inference_config.visible = false
    download_hint_label.text = "[b]Chat[/b]\nUse [i]Load Model[/i] in the chat toolbar before sending prompts."


# Connected in the scene to DownloadModelsButton.pressed.
func _on_download_models_button_pressed() -> void:
    _show_configuration("model")
    download_hint_label.text = "[b]Models[/b]\nDownload a GGUF model in the editor’s Local Agents panel, then select it here."



func _on_exit_button_pressed() -> void:
    get_tree().quit()

func _show_configuration(section: String) -> void:
    $HBoxContainer/ChatVBoxContainer.visible = false
    model_config.visible = section == "model"
    inference_config.visible = section == "inference"
    download_hint_label.text = "[b]Model setup[/b]\nChoose your settings, then return to Chat."
