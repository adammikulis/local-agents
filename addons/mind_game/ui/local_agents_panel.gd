extends Control

const CHAT_SCENE := preload("res://addons/mind_game/examples/chat_example.tscn")
const DOWNLOAD_PANEL_SCENE := preload("res://addons/mind_game/ui/model_download_panel.tscn")

@onready var _chat_placeholder: Control = %ChatTab
@onready var _download_placeholder: Control = %DownloadTab

func _ready() -> void:
    _mount_scene(CHAT_SCENE, _chat_placeholder)
    _mount_scene(DOWNLOAD_PANEL_SCENE, _download_placeholder)

func _mount_scene(scene: PackedScene, placeholder: Control) -> void:
    if scene == null or placeholder == null:
        return
    var instance = scene.instantiate()
    placeholder.add_child(instance)
    if instance is Control:
        var control := instance as Control
        control.set_anchors_preset(PRESET_FULL_RECT)
        control.anchor_right = 1.0
        control.anchor_bottom = 1.0
        control.offset_left = 0.0
        control.offset_top = 0.0
        control.offset_right = 0.0
        control.offset_bottom = 0.0
