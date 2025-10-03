@tool
extends EditorPlugin

var agent_script := load("res://addons/local_agents/agents/Agent.gd")
var agent_icon := load("res://addons/local_agents/assets/logos/brain_pink.png")

var _extension_res: Extension

func _enter_tree() -> void:
    _ensure_extension_loaded()
    add_custom_type("Agent", "Node", agent_script, agent_icon)

func _exit_tree() -> void:
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
