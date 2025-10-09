extends EditorPlugin

const AUTOLOAD_NAME := "MindManager"
const AUTOLOAD_PATH := "res://addons/mind_game/mind_manager/mind_manager.gd"
var _autoload_added := false

func _enter_tree() -> void:
    if not Engine.has_singleton(AUTOLOAD_NAME) and not ProjectSettings.has_setting("autoload/" + AUTOLOAD_NAME):
        add_autoload_singleton(AUTOLOAD_NAME, AUTOLOAD_PATH)
        _autoload_added = true
    else:
        _autoload_added = false

func _exit_tree() -> void:
    if _autoload_added and ProjectSettings.has_setting("autoload/" + AUTOLOAD_NAME):
        remove_autoload_singleton(AUTOLOAD_NAME)
