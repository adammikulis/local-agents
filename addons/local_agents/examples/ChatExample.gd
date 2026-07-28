extends Node

## The sidebar navigation for the full chat example — which panel is showing, and the tip that goes
## with it. That is all this scene needs a script for.
##
## The chat itself is the ChatController scene; the model and sampling editors are the ModelConfig
## and InferenceConfig scenes; the readiness readout is the SetupStatus label (LocalAgentStatusLabel),
## which polls LocalAgentStatus on its own timer. None of those are built or refreshed here.
##
## (Explicit types only — project rule: no ':=' inferred typing.)

@onready var chat_controller: LocalAgentChatController = %ChatController
@onready var saved_controller: LocalAgentSavedChatsController = %SavedChatsController
@onready var inference_config: LocalAgentInferenceConfig = %InferenceConfig
@onready var model_config: LocalAgentModelConfig = %ModelConfig
@onready var home_button: Button = %HomeButton
@onready var chat_button: Button = %ChatButton
@onready var download_models_button: Button = %DownloadModelsButton
@onready var exit_button: Button = %ExitButton
@onready var download_hint_label: RichTextLabel = %DownloadHintLabel

func _ready() -> void:
    home_button.pressed.connect(_show_home)
    chat_button.pressed.connect(_show_chat)
    download_models_button.pressed.connect(_show_download_help)
    exit_button.pressed.connect(func() -> void: get_tree().quit())
    if saved_controller:
        saved_controller.hide()
    _show_chat()

func _show_home() -> void:
    chat_controller.visible = false
    model_config.visible = true
    inference_config.visible = true
    download_hint_label.text = "[b]Home[/b]\nCheck the setup status above, then open Chat when the model is ready."

func _show_chat() -> void:
    chat_controller.visible = true
    model_config.visible = false
    inference_config.visible = false
    download_hint_label.text = "[b]Chat[/b]\nUse [i]Load Model[/i] in the chat toolbar before sending prompts."

func _show_download_help() -> void:
    chat_controller.visible = false
    model_config.visible = true
    inference_config.visible = true
    download_hint_label.text = "[b]Downloads[/b]\nOpen the editor bottom panel: [i]Local Agents -> Downloads[/i], fetch a model, then return to Chat and press [i]Load Model[/i]."
