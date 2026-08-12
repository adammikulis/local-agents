extends Node


@onready var chat_controller: LAChatController = %ChatController
@onready var inference_config: LAInferenceConfig = %InferenceConfig
@onready var model_config: LAModelConfig = %ModelConfig
@onready var download_hint_label: RichTextLabel = %DownloadHintLabel


# Connected in the scene to HomeButton.pressed.
func _on_home_button_pressed() -> void:
    chat_controller.visible = false
    model_config.visible = true
    inference_config.visible = true
    download_hint_label.text = "[b]Home[/b]\nCheck the setup status above, then open Chat when the model is ready."


# Connected in the scene to ChatButton.pressed. This is the state the scene is saved in.
func _on_chat_button_pressed() -> void:
    chat_controller.visible = true
    model_config.visible = false
    inference_config.visible = false
    download_hint_label.text = "[b]Chat[/b]\nUse [i]Load Model[/i] in the chat toolbar before sending prompts."


# Connected in the scene to DownloadModelsButton.pressed.
func _on_download_models_button_pressed() -> void:
    chat_controller.visible = false
    model_config.visible = true
    inference_config.visible = true
    download_hint_label.text = "[b]Downloads[/b]\nOpen the editor bottom panel: [i]Local Agents -> Downloads[/i], fetch a model, then return to Chat and press [i]Load Model[/i]."


func _on_exit_button_pressed() -> void:
    get_tree().quit()
