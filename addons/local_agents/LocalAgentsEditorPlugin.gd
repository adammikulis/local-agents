@tool
extends EditorPlugin

# CORE agent-library scripts — always present in any install, so a top-level preload is safe. The plugin
# must NOT top-level-preload any voxel/game script: the voxel tree is OPTIONAL (an agent-only install may
# delete scenes/simulation/), and a top-level preload of a deleted path fail-parses the WHOLE plugin. The
# game nodes are registered separately via a guarded load() below (absence = graceful skip, not a parse error).
const AGENT_SCRIPT := preload("res://addons/local_agents/agents/Agent.gd")
const AGENT3D_SCRIPT := preload("res://addons/local_agents/agents/Agent3D.gd")
const GRAPH_SCRIPT := preload("res://addons/local_agents/graph/Graph.gd")
const PANEL_SCENE := preload("res://addons/local_agents/editor/LocalAgentsPanel.tscn")
const EXTENSION_LOADER := preload("res://addons/local_agents/runtime/LocalAgentsExtensionLoader.gd")

const EDITOR_ENABLED_SETTING := "local_agents/editor/enabled"

# OPTIONAL game/voxel nodes: {display name, base class, res:// script path}. Registered only if the script
# file exists (load() at runtime, never preload) so deleting the voxel tree leaves the agent nodes intact.
const GAME_TYPES := [
    {"name": "Creature", "base": "CharacterBody3D", "path": "res://addons/local_agents/creatures/Creature.gd"},
    {"name": "Sim World", "base": "Node3D", "path": "res://addons/local_agents/scenes/simulation/voxel/world/SimWorld.gd"},
]

var _panel_instance: Control
var _panel_button: Button
var _editor_active := false
var _panel_loaded := false
var _custom_type_registered := false
# Every custom type name this plugin registered (agent + any present game nodes), for clean removal.
var _registered_type_names: Array = []

func _enter_tree() -> void:
    if not Engine.is_editor_hint():
        return
    _editor_active = true
    _create_placeholder_panel()
    if _should_auto_activate():
        call_deferred("_activate_panel")

func _exit_tree() -> void:
    if not _editor_active:
        return
    if _panel_instance:
        remove_control_from_bottom_panel(_panel_instance)
        _panel_instance.queue_free()
    if _custom_type_registered:
        for type_name in _registered_type_names:
            remove_custom_type(type_name)
        _registered_type_names.clear()
        _custom_type_registered = false
    _panel_instance = null
    _panel_button = null
    _panel_loaded = false
    _editor_active = false

func make_visible(visible: bool) -> void:
    if visible and not _panel_loaded:
        _activate_panel()
    if _panel_instance:
        _panel_instance.visible = visible

func _create_placeholder_panel() -> void:
    if _panel_instance:
        return
    var container := VBoxContainer.new()
    container.name = "LocalAgentsPlaceholder"
    container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    container.size_flags_vertical = Control.SIZE_EXPAND_FILL
    var label := RichTextLabel.new()
    label.bbcode_enabled = true
    label.fit_content = true
    label.autowrap_mode = TextServer.AUTOWRAP_WORD
    label.text = "[b]Local Agents[/b]\nEditor tools stay inactive until activated to avoid long startup times."
    label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    label.size_flags_vertical = Control.SIZE_EXPAND_FILL
    container.add_child(label)
    var button := Button.new()
    button.text = "Activate Local Agents"
    button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
    button.pressed.connect(func(): _activate_panel(true))
    container.add_child(button)
    _panel_instance = container
    _panel_button = add_control_to_bottom_panel(_panel_instance, "Local Agents")

func _activate_panel(save_preference: bool = false) -> void:
    if _panel_loaded:
        _show_bottom_panel()
        return
    if not EXTENSION_LOADER.ensure_initialized():
        push_error("Local Agents extension unavailable: %s" % EXTENSION_LOADER.get_error())
        return
    _register_agent_type()
    _swap_in_panel_scene()
    _panel_loaded = true
    _show_bottom_panel()
    if save_preference:
        _set_plugin_enabled(true)
    _ensure_agent_manager_ready()

func _swap_in_panel_scene() -> void:
    if _panel_instance:
        remove_control_from_bottom_panel(_panel_instance)
        _panel_instance.queue_free()
    _panel_instance = PANEL_SCENE.instantiate()
    if not _panel_instance:
        push_error("Failed to instantiate Local Agents panel")
        _create_placeholder_panel()
        return
    _panel_button = add_control_to_bottom_panel(_panel_instance, "Local Agents")

func _register_agent_type() -> void:
    if _custom_type_registered:
        return
    # Core agent nodes (always present). No dedicated icons ship with the addon → null (reuses the base-class
    # icon), matching the historical Agent registration.
    add_custom_type("Agent", "Node", AGENT_SCRIPT, null)
    _registered_type_names.append("Agent")
    add_custom_type("LocalAgent3D", "CharacterBody3D", AGENT3D_SCRIPT, null)
    _registered_type_names.append("LocalAgent3D")
    add_custom_type("LocalAgentGraph", "Resource", GRAPH_SCRIPT, null)
    _registered_type_names.append("LocalAgentGraph")
    _register_game_types()
    _custom_type_registered = true

# Register the OPTIONAL game/voxel nodes only when their scripts are present. Uses ResourceLoader.exists +
# load() (never a top-level preload) so an agent-only install with the voxel tree deleted skips them cleanly
# with zero parse errors. A failed/missing load is simply not registered.
func _register_game_types() -> void:
    for entry_variant in GAME_TYPES:
        var entry: Dictionary = entry_variant
        var path: String = String(entry["path"])
        if not ResourceLoader.exists(path):
            continue
        var script_res: Script = load(path)
        if script_res == null:
            continue
        add_custom_type(String(entry["name"]), String(entry["base"]), script_res, null)
        _registered_type_names.append(String(entry["name"]))

func _ensure_agent_manager_ready() -> void:
    var manager := get_node_or_null("/root/AgentManager")
    if manager and manager.has_method("_ensure_agent"):
        manager.call("_ensure_agent")

func _show_bottom_panel() -> void:
    if _panel_instance and _panel_button:
        make_bottom_panel_item_visible(_panel_instance)

func _should_auto_activate() -> bool:
    return ProjectSettings.get_setting(EDITOR_ENABLED_SETTING, false)

func _set_plugin_enabled(enabled: bool) -> void:
    ProjectSettings.set_setting(EDITOR_ENABLED_SETTING, enabled)
    ProjectSettings.save()
