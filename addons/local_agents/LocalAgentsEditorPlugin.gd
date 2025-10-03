@tool
extends EditorPlugin

var agent_script := load("res://addons/local_agents/agents/Agent.gd")
var agent_icon := load("res://addons/local_agents/assets/logos/brain_pink.png")
var panel_scene := load("res://addons/local_agents/editor/LocalAgentsPanel.tscn")

var _extension_res: Extension
var _panel_instance: Control
var _panel_button: Button

func _enter_tree() -> void:
    _ensure_extension_loaded()
    add_custom_type("Agent", "Node", agent_script, agent_icon)
    _create_bottom_panel()

func _exit_tree() -> void:
    if _panel_instance:
        remove_control_from_bottom_panel(_panel_instance)
        _panel_instance.queue_free()
        _panel_instance = null
        _panel_button = null
    remove_custom_type("Agent")
    if _extension_res and _extension_res.is_initialized():
        _extension_res.deinitialize()
        _extension_res = null

func _ensure_extension_loaded() -> void:
    if ClassDB.class_exists("AgentNode"):
        return
    var res := load("res://addons/local_agents/gdextensions/localagents/localagents.gdextension")
    if res and res is Extension:
        _extension_res = res
        if not _extension_res.is_initialized():
            var err := _extension_res.initialize()
            if err != OK:
                push_error("Failed to initialize localagents extension: %s" % err)
    elif not res:
        push_error("Failed to load localagents.gdextension resource")

func _create_bottom_panel() -> void:
    if not panel_scene:
        push_error("Local Agents panel scene missing")
        return
    if _panel_instance:
        return
    _panel_instance = panel_scene.instantiate()
    if not _panel_instance:
        push_error("Failed to instantiate Local Agents panel")
        return
    _panel_button = add_control_to_bottom_panel(_panel_instance, "Local Agents")
    if _panel_button and agent_icon:
        _panel_button.icon = agent_icon
