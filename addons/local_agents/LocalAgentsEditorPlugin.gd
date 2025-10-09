@tool
extends EditorPlugin

const AGENT_SCRIPT := preload("res://addons/local_agents/agents/Agent.gd")
const PANEL_SCENE := preload("res://addons/local_agents/editor/LocalAgentsPanel.tscn")
const EXTENSION_LOADER := preload("res://addons/local_agents/runtime/LocalAgentsExtensionLoader.gd")

const EDITOR_ENABLED_SETTING := "local_agents/editor/enabled"

var _panel_instance: Control
var _panel_button: Button
var _editor_active := false
var _panel_loaded := false
var _custom_type_registered := false

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
        remove_custom_type("Agent")
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
    add_custom_type("Agent", "Node", AGENT_SCRIPT, null)
    _custom_type_registered = true

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
