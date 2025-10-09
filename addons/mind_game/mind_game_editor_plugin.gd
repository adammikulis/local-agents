extends EditorPlugin

const AUTOLOAD_NAME := "MindManager"
const AUTOLOAD_PATH := "res://addons/mind_game/mind_manager/mind_manager.gd"
const PANEL_SCENE := preload("res://addons/mind_game/ui/local_agents_panel.tscn")

var _autoload_added := false
var _panel_instance: Control

func _enter_tree() -> void:
    if not Engine.has_singleton(AUTOLOAD_NAME) and not ProjectSettings.has_setting("autoload/" + AUTOLOAD_NAME):
        add_autoload_singleton(AUTOLOAD_NAME, AUTOLOAD_PATH)
        _autoload_added = true
    else:
        _autoload_added = false

    if PANEL_SCENE:
        _panel_instance = PANEL_SCENE.instantiate()
        add_control_to_bottom_panel(_panel_instance, "Local Agents")

func _exit_tree() -> void:
    if _autoload_added and ProjectSettings.has_setting("autoload/" + AUTOLOAD_NAME):
        remove_autoload_singleton(AUTOLOAD_NAME)
    if _panel_instance:
        remove_control_from_bottom_panel(_panel_instance)
        _panel_instance.queue_free()
        _panel_instance = null
