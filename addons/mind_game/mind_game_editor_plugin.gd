extends EditorPlugin

const AUTOLOAD_NAME := "LocalAgentManager"
const AUTOLOAD_PATH := "res://addons/mind_game/mind_manager/local_agent_manager.gd"
const LEGACY_AUTOLOAD_NAME := "MindManager"
const LEGACY_AUTOLOAD_PATH := "res://addons/mind_game/mind_manager/mind_manager.gd"
const PANEL_SCENE := preload("res://addons/mind_game/ui/local_agents_panel.tscn")

var _autoload_added := false
var _panel_instance: Control

func _enter_tree() -> void:
    _autoload_added = false

    _migrate_legacy_autoload()

    if not Engine.has_singleton(AUTOLOAD_NAME) and not ProjectSettings.has_setting("autoload/" + AUTOLOAD_NAME):
        add_autoload_singleton(AUTOLOAD_NAME, AUTOLOAD_PATH)
        _autoload_added = true

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

func _migrate_legacy_autoload() -> void:
    if not ProjectSettings.has_setting("autoload/" + LEGACY_AUTOLOAD_NAME):
        return

    var autoload_setting := ProjectSettings.get_setting("autoload/" + LEGACY_AUTOLOAD_NAME)
    var autoload_path := _get_autoload_path(autoload_setting)

    if autoload_path != LEGACY_AUTOLOAD_PATH:
        return

    remove_autoload_singleton(LEGACY_AUTOLOAD_NAME)

    if not ProjectSettings.has_setting("autoload/" + AUTOLOAD_NAME):
        add_autoload_singleton(AUTOLOAD_NAME, AUTOLOAD_PATH)

func _get_autoload_path(setting) -> String:
    match typeof(setting):
        TYPE_DICTIONARY:
            var path_value = setting.get("path", "")
            if typeof(path_value) == TYPE_STRING:
                return _sanitize_autoload_path(path_value)
            return ""
        TYPE_STRING:
            return _sanitize_autoload_path(setting)
        _:
            return ""

func _sanitize_autoload_path(path_value: String) -> String:
    var path := path_value
    if path.begins_with("*"):
        path = path.substr(1)
    return path
