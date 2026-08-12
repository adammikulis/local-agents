@tool
extends EditorPlugin


const PANEL_SCENE: PackedScene = preload("res://addons/local_agents/editor/LocalAgentPanel.tscn")
const SETUP_TAB_SCENE: PackedScene = preload("res://addons/local_agents/editor/SetupTab.tscn")
const CHOICE_INSPECTOR_SCRIPT: GDScript = preload("res://addons/local_agents/editor/ChoiceInspectorPlugin.gd")
const EXTENSION_LOADER: GDScript = preload("res://addons/local_agents/runtime/LocalAgentExtensionLoader.gd")
const SETTINGS: GDScript = preload("res://addons/local_agents/runtime/Settings.gd")

const AUTOLOAD_NAME: String = "AgentManager"
const AUTOLOAD_PATH: String = "res://addons/local_agents/agent_manager/AgentManager.gd"
const AUTOLOAD_SETTING: String = "autoload/AgentManager"
const EDITOR_ENABLED_SETTING: String = "local_agents/editor/enabled"

var _panel_instance: Control = null
var _panel_button: Button = null
var _editor_active: bool = false
var _panel_loaded: bool = false
# True only when THIS plugin added the autoload, so disabling the plugin never removes an entry the
# project author wrote themselves.
var _autoload_registered: bool = false
# Supplies pick-lists for the String properties whose valid values are discovered from disk
# (species ids, Piper voices, installed .gguf files).
var _choice_inspector: EditorInspectorPlugin = null

func _enter_tree() -> void:
    if not Engine.is_editor_hint():
        return
    _editor_active = true
    _register_settings()
    _register_autoload()
    _register_inspector()
    _create_setup_panel()
    if _should_auto_activate():
        call_deferred("_activate_panel")

## Dropdowns for species / voice / model_path. Purely an editor convenience: with the plugin off,
## every one of those is an ordinary String field and nothing at runtime changes.
func _register_inspector() -> void:
    if _choice_inspector != null:
        return
    _choice_inspector = CHOICE_INSPECTOR_SCRIPT.new()
    add_inspector_plugin(_choice_inspector)

func _exit_tree() -> void:
    if not _editor_active:
        return
    if _panel_instance:
        remove_control_from_bottom_panel(_panel_instance)
        _panel_instance.queue_free()
    if _autoload_registered:
        remove_autoload_singleton(AUTOLOAD_NAME)
        _autoload_registered = false
    if _choice_inspector != null:
        remove_inspector_plugin(_choice_inspector)
        _choice_inspector = null
    _panel_instance = null
    _panel_button = null
    _panel_loaded = false
    _editor_active = false

func make_visible(visible: bool) -> void:
    if visible and not _panel_loaded:
        _activate_panel()
    if _panel_instance:
        _panel_instance.visible = visible


## Publish every LocalAgentSettings spec so Project Settings renders it as a typed row (file picker,
## enum, checkbox) instead of the user hand-editing project.godot. Existing values are never
## overwritten — only absent keys get seeded — so re-enabling the plugin is not destructive.
func _register_settings() -> void:
    var wrote_any: bool = false
    for spec_variant in SETTINGS.specs():
        var spec: Dictionary = spec_variant
        var setting_name: String = String(spec["name"])
        var default_value: Variant = spec["default"]
        if not ProjectSettings.has_setting(setting_name):
            ProjectSettings.set_setting(setting_name, default_value)
            wrote_any = true
        ProjectSettings.set_initial_value(setting_name, default_value)
        ProjectSettings.set_as_basic(setting_name, true)
        ProjectSettings.add_property_info({
            "name": setting_name,
            "type": int(spec["type"]),
            "hint": int(spec["hint"]),
            "hint_string": String(spec["hint_string"]),
        })
    if wrote_any:
        ProjectSettings.save()

## The AgentManager autoload is REQUIRED — LocalAgent nodes resolve it as /root/AgentManager. It is
## registered here (in _enter_tree), not in _activate_panel, because it must exist whether or not the
## native library loaded and whether or not the bottom panel was ever opened.
func _register_autoload() -> void:
    if ProjectSettings.has_setting(AUTOLOAD_SETTING):
        # Already present (this project wrote it, or a previous enable did). Leave it alone.
        return
    if not ResourceLoader.exists(AUTOLOAD_PATH):
        push_warning("Local Agents: cannot register the AgentManager autoload, %s is missing." % AUTOLOAD_PATH)
        return
    add_autoload_singleton(AUTOLOAD_NAME, AUTOLOAD_PATH)
    _autoload_registered = true


## The panel that exists before (and without) activation: the Setup checklist. It renders with no
## native binary, which is the entire point — it is what tells you how to get one.
func _create_setup_panel() -> void:
    if _panel_instance:
        return
    var setup: Control = SETUP_TAB_SCENE.instantiate()
    setup.name = "LocalAgentSetup"
    setup.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    setup.size_flags_vertical = Control.SIZE_EXPAND_FILL
    _panel_instance = setup
    _wire_setup_tabs(_panel_instance)
    _panel_button = add_control_to_bottom_panel(_panel_instance, "Local Agents")

func _activate_panel(save_preference: bool = false) -> void:
    if _panel_loaded:
        _show_bottom_panel()
        return
    # Best-effort only. A failed load is reported by the Setup tab (with the expected library path
    # and a fix sentence) rather than swallowing the whole UI.
    EXTENSION_LOADER.ensure_initialized()
    _swap_in_panel_scene()
    _panel_loaded = true
    _show_bottom_panel()
    if save_preference:
        _set_plugin_enabled(true)
    _ensure_agent_manager_ready()

func _swap_in_panel_scene() -> void:
    var previous: Control = _panel_instance
    var full_panel: Control = PANEL_SCENE.instantiate()
    if full_panel == null:
        push_error("Failed to instantiate the Local Agents panel; keeping the Setup checklist.")
        return
    if previous:
        remove_control_from_bottom_panel(previous)
        previous.queue_free()
    _panel_instance = full_panel
    _wire_setup_tabs(_panel_instance)
    _panel_button = add_control_to_bottom_panel(_panel_instance, "Local Agents")

# Connect every Setup tab in a subtree (the standalone checklist, or the one inside the full panel).
# Matched by signal rather than by class so a not-yet-scanned class_name cannot break the plugin.
func _wire_setup_tabs(root: Node) -> void:
    if root == null:
        return
    if root.has_signal("activate_requested") and root.has_signal("register_autoload_requested"):
        if not root.is_connected("activate_requested", Callable(self, "_on_setup_activate_requested")):
            root.connect("activate_requested", Callable(self, "_on_setup_activate_requested"))
        if not root.is_connected("register_autoload_requested", Callable(self, "_on_setup_register_autoload_requested")):
            root.connect("register_autoload_requested", Callable(self, "_on_setup_register_autoload_requested"))
    for child in root.get_children():
        _wire_setup_tabs(child)

func _on_setup_activate_requested() -> void:
    _activate_panel(true)

func _on_setup_register_autoload_requested() -> void:
    if ProjectSettings.has_setting(AUTOLOAD_SETTING):
        return
    _register_autoload()
    ProjectSettings.save()

func _ensure_agent_manager_ready() -> void:
    var manager: Node = get_node_or_null("/root/AgentManager")
    if manager and manager.has_method("_ensure_agent"):
        manager.call("_ensure_agent")

func _show_bottom_panel() -> void:
    if _panel_instance and _panel_button:
        make_bottom_panel_item_visible(_panel_instance)

func _should_auto_activate() -> bool:
    return SETTINGS.get_bool(EDITOR_ENABLED_SETTING)

func _set_plugin_enabled(enabled: bool) -> void:
    ProjectSettings.set_setting(EDITOR_ENABLED_SETTING, enabled)
    ProjectSettings.save()
