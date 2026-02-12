extends Node
class_name LocalAgentsChatExample

@onready var chat_controller: LocalAgentsChatController = %ChatController
@onready var saved_controller: LocalAgentsSavedChatsController = %SavedChatsController
@onready var inference_config: LocalAgentsInferenceConfig = %InferenceConfig
@onready var model_config: LocalAgentsModelConfig = %ModelConfig
@onready var home_button: Button = %HomeButton
@onready var chat_button: Button = %ChatButton
@onready var download_models_button: Button = %DownloadModelsButton
@onready var exit_button: Button = %ExitButton
@onready var refresh_status_button: Button = %RefreshStatusButton
@onready var runtime_status_label: Label = %RuntimeStatusLabel
@onready var model_status_label: Label = %ModelStatusLabel
@onready var download_hint_label: RichTextLabel = %DownloadHintLabel

const ExtensionLoader := preload("res://addons/local_agents/runtime/LocalAgentsExtensionLoader.gd")
const RuntimePaths := preload("res://addons/local_agents/runtime/RuntimePaths.gd")

func _ready() -> void:
    home_button.pressed.connect(_show_home)
    chat_button.pressed.connect(_show_chat)
    download_models_button.pressed.connect(_show_download_help)
    exit_button.pressed.connect(func() -> void: get_tree().quit())
    refresh_status_button.pressed.connect(_refresh_hud_status)
    if saved_controller:
        saved_controller.hide()
    _show_chat()
    _refresh_hud_status()

func _show_home() -> void:
    chat_controller.visible = false
    model_config.visible = true
    inference_config.visible = true
    download_hint_label.visible = true
    download_hint_label.text = "[b]Home[/b]\nCheck runtime health below, then open Chat when the model is ready."
    _refresh_hud_status()

func _show_chat() -> void:
    chat_controller.visible = true
    model_config.visible = false
    inference_config.visible = false
    download_hint_label.visible = true
    download_hint_label.text = "[b]Chat[/b]\nUse [i]Load Model[/i] in the chat toolbar before sending prompts."
    _refresh_hud_status()

func _show_download_help() -> void:
    chat_controller.visible = false
    model_config.visible = true
    inference_config.visible = true
    download_hint_label.visible = true
    download_hint_label.text = "[b]Downloads[/b]\nOpen the editor bottom panel: [i]Local Agents -> Downloads[/i], fetch a model, then return to Chat and press [i]Load Model[/i]."
    _refresh_hud_status()

func _refresh_hud_status() -> void:
    var runtime_ok := ExtensionLoader.ensure_initialized()
    if runtime_ok:
        runtime_status_label.text = "Runtime: Ready"
    else:
        var runtime_error := ExtensionLoader.get_error()
        if runtime_error.is_empty():
            runtime_error = "Unavailable"
        runtime_status_label.text = "Runtime: %s" % runtime_error

    var default_model := RuntimePaths.resolve_default_model()
    if default_model.is_empty():
        model_status_label.text = "Model: Missing default model in user://local_agents/models"
    else:
        model_status_label.text = "Model: Found %s" % default_model.get_file()
