@tool
extends Control
class_name LASetupTab


const Status: GDScript = preload("res://addons/local_agents/runtime/AgentStatus.gd")

## Emitted when the checklist is running standalone (before the full bottom panel exists) and the
## user asks for the real panel. The plugin swaps it in.
signal activate_requested()

## Emitted by the AgentManager row's button. The plugin owns `add_autoload_singleton`, so the fix is
## performed there rather than by poking project.godot from a Control.
signal register_autoload_requested()

@export_group("Checklist")
## Seconds between automatic re-checks while the tab is on screen. Set to 0 to only refresh when the
## Re-check button is pressed (useful if you are watching a slow build in another terminal).
@export_range(0.0, 30.0, 0.5, "suffix:s") var refresh_interval_seconds: float = 3.0
## Also list advisory items, meaning the speech runtime and the godot_voxel backend. Neither blocks
## text generation, so turn this off for a blockers-only view.
@export var show_optional_items: bool = true

@export_group("Links")
## Documentation opened by the native-extension row. A res:// markdown file, opened in your default
## editor. Lives inside the addon so it still resolves in an addon-only install.
@export_file("*.md") var install_doc_path: String = "res://addons/local_agents/docs/INSTALL.md"
## Fallback documentation when `install_doc_path` does not exist. Also inside the addon: a project
## that copied only addons/local_agents/ has no repo-root README to fall back to.
@export_file("*.md") var fallback_doc_path: String = "res://addons/local_agents/docs/USAGE.md"
## Opened by the godot_voxel row. That GDExtension is only needed for SimWorld's SPHERE mode.
@export var voxel_addon_url: String = "https://github.com/Zylann/godot_voxel"

@export_group("Presentation")
## Colour of a satisfied row.
@export var ok_color: Color = Color(0.42, 0.79, 0.45)
## Colour of a row that blocks text generation.
@export var blocked_color: Color = Color(0.91, 0.42, 0.42)
## Colour of an advisory row (optional feature unavailable).
@export var advisory_color: Color = Color(0.93, 0.76, 0.35)

@onready var _headline_label: Label = %HeadlineLabel
@onready var _next_step_label: Label = %NextStepLabel
@onready var _rows_box: VBoxContainer = %RowsBox
@onready var _recheck_button: Button = %RecheckButton
@onready var _activate_button: Button = %ActivateButton
@onready var _detail_label: Label = %DetailLabel
@onready var _timer: Timer = %RefreshTimer
# One entry per checklist row: {"spec": Dictionary, "badge": Label, "title": Label, "detail": Label,
# "button": Button, "container": HBoxContainer}. Built once; refresh only updates text/visibility so
# a 3-second poll never steals focus from a button mid-click.
var _rows: Array = []


func _row_specs() -> Array:
    return [
        {
            "needs": "extension",
            "title": "Native extension",
            "ok_text": "Loaded. The llama.cpp runtime is available.",
            "advisory": false,
            "action": "Copy expected path",
            "handler": "_on_extension_action",
        },
        {
            "needs": "autoload",
            "title": "AgentManager autoload",
            "ok_text": "Registered at /root/AgentManager.",
            "advisory": false,
            "action": "Register autoload",
            "handler": "_on_autoload_action",
        },
        {
            "needs": "model",
            "title": "GGUF model",
            "ok_text": "A model file is installed and resolvable.",
            "advisory": false,
            "action": "Open Downloads",
            "handler": "_on_model_action",
        },
        {
            "needs": "speech",
            "title": "Speech runtime (optional)",
            "ok_text": "Piper is present; agents can speak aloud.",
            "advisory": true,
            "action": "Open Downloads",
            "handler": "_on_model_action",
        },
        {
            "needs": "voxel",
            "title": "godot_voxel backend (optional)",
            "ok_text": "Installed. SimWorld SPHERE mode is available.",
            "advisory": true,
            "action": "Open godot_voxel",
            "handler": "_on_voxel_action",
        },
    ]


func _ready() -> void:
    _recheck_button.pressed.connect(refresh)
    _activate_button.pressed.connect(_on_activate_pressed)
    _timer.timeout.connect(refresh)
    # Only meaningful while this checklist IS the whole panel; inside the TabContainer the other tabs
    # are already there.
    _activate_button.visible = not (get_parent() is TabContainer)
    _build_rows()
    _apply_refresh_interval()
    refresh()

func _notification(what: int) -> void:
    if what == NOTIFICATION_VISIBILITY_CHANGED and is_visible_in_tree() and _rows_box != null:
        refresh()


func _build_rows() -> void:
    for spec_variant in _row_specs():
        var spec: Dictionary = spec_variant
        var container: HBoxContainer = HBoxContainer.new()
        container.add_theme_constant_override("separation", 10)
        container.size_flags_horizontal = Control.SIZE_EXPAND_FILL

        var badge: Label = Label.new()
        badge.custom_minimum_size = Vector2(52, 0)
        badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
        container.add_child(badge)

        var text_column: VBoxContainer = VBoxContainer.new()
        text_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
        text_column.add_theme_constant_override("separation", 2)
        container.add_child(text_column)

        var title: Label = Label.new()
        title.text = String(spec["title"])
        text_column.add_child(title)

        var detail: Label = Label.new()
        detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
        detail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
        detail.add_theme_font_size_override("font_size", 11)
        text_column.add_child(detail)

        var button: Button = Button.new()
        button.text = String(spec["action"])
        button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
        button.visible = String(spec["action"]) != ""
        button.pressed.connect(Callable(self, String(spec["handler"])))
        container.add_child(button)

        _rows_box.add_child(container)
        _rows.append({
            "spec": spec,
            "container": container,
            "badge": badge,
            "title": title,
            "detail": detail,
            "button": button,
        })

func _apply_refresh_interval() -> void:
    if _timer == null:
        return
    if refresh_interval_seconds <= 0.0:
        _timer.stop()
        return
    _timer.wait_time = refresh_interval_seconds
    _timer.start()


## Re-run the checks and repaint. Safe to call at any time; it only reads LocalAgentStatus.
func refresh() -> void:
    if _rows_box == null:
        return
    var state: Dictionary = Status.check()
    _headline_label.text = String(state["headline"])
    _headline_label.add_theme_color_override("font_color", _level_color(int(state["level"])))

    var next_step: String = String(state["next_step"])
    if next_step == "":
        _next_step_label.text = "Nothing is blocking generation."
    else:
        _next_step_label.text = "Next: %s" % next_step

    for row_variant in _rows:
        var row: Dictionary = row_variant
        _refresh_row(row, state)

    _detail_label.text = _details_text(state)
    _apply_refresh_interval()

func _refresh_row(row: Dictionary, state: Dictionary) -> void:
    var spec: Dictionary = row["spec"]
    var advisory: bool = bool(spec["advisory"])
    var container: HBoxContainer = row["container"]
    if advisory and not show_optional_items:
        container.visible = false
        return
    container.visible = true

    # Reuse the state refresh() already computed. warnings_for() would re-probe the filesystem, the
    # extension loader and ClassDB for every row, which is six full probes per tick in the editor.
    var problems: PackedStringArray = Status.warnings_for_state(state, _needs_for(String(spec["needs"])))
    var ok: bool = problems.is_empty()
    var badge: Label = row["badge"]
    var detail: Label = row["detail"]
    var button: Button = row["button"]

    var color: Color = ok_color
    var badge_text: String = "OK"
    if not ok:
        if advisory:
            color = advisory_color
            badge_text = "OPT"
        else:
            color = blocked_color
            badge_text = "FIX"
    badge.text = badge_text
    badge.add_theme_color_override("font_color", color)

    var detail_color: Color = Color(0.72, 0.72, 0.72)
    if ok:
        detail.text = String(spec["ok_text"])
    else:
        detail.text = " ".join(problems)
        detail_color = color
    detail.add_theme_color_override("font_color", detail_color)

    # The extension row's button stays useful once loaded (copying the path is how you report a
    # mismatch); the rest only make sense while the row is unresolved.
    button.visible = String(spec["action"]) != "" and (not ok or String(spec["needs"]) == "extension")
    button.disabled = ok and String(spec["needs"]) != "extension"

# `warnings_for` defaults `extension` to true, so every non-extension row must switch it off or it
# would report the extension's problem under its own title.
func _needs_for(key: String) -> Dictionary:
    return {
        "extension": key == "extension",
        "autoload": key == "autoload",
        "model": key == "model",
        "speech": key == "speech",
        "voxel": key == "voxel",
    }

func _level_color(level: int) -> Color:
    if level == Status.Level.READY:
        return ok_color
    if level == Status.Level.DEGRADED:
        return advisory_color
    return blocked_color

func _details_text(state: Dictionary) -> String:
    var lines: Array[String] = []
    lines.append("Expected native library: %s" % String(state["expected_library_path"]))
    var extension_error: String = String(state["extension_error"])
    if extension_error != "":
        lines.append("Extension error: %s" % extension_error)
    var model_path: String = String(state["model_path"])
    if model_path != "":
        lines.append("Model: %s" % model_path)
    else:
        lines.append("Model search order: %s" % ", ".join(state["model_candidates"]))
    lines.append("Runtime binaries: %s" % String(state["runtime_dir"]))
    return "\n".join(lines)


func _on_activate_pressed() -> void:
    activate_requested.emit()

func _on_extension_action() -> void:
    var expected: String = Status.expected_library_path()
    if expected != "":
        DisplayServer.clipboard_set(expected)
    _open_install_doc()
    refresh()

func _on_autoload_action() -> void:
    register_autoload_requested.emit()
    refresh()

func _on_model_action() -> void:
    _focus_downloads_tab()

func _on_voxel_action() -> void:
    if voxel_addon_url != "":
        OS.shell_open(voxel_addon_url)

# FileAccess.file_exists, not ResourceLoader.exists: Godot ships no ResourceFormatLoader for .md, so
# ResourceLoader.exists() is false for every markdown file that is sitting right there on disk. Using
# it here made this button a silent no-op.
func _open_install_doc() -> void:
    var doc: String = install_doc_path
    if doc == "" or not FileAccess.file_exists(doc):
        doc = fallback_doc_path
    if doc == "" or not FileAccess.file_exists(doc):
        push_warning("Local Agents: install doc not found at %s or %s" % [install_doc_path, fallback_doc_path])
        return
    OS.shell_open(ProjectSettings.globalize_path(doc))

# Select the sibling Downloads tab. When this checklist is standalone (the pre-activation panel)
# there is no sibling yet, so ask the plugin to swap the full panel in instead.
func _focus_downloads_tab() -> void:
    var tabs: TabContainer = get_parent() as TabContainer
    if tabs == null:
        activate_requested.emit()
        return
    for index: int in range(tabs.get_tab_count()):
        var control: Control = tabs.get_tab_control(index)
        if control != null and control.has_method("download_models_only"):
            tabs.current_tab = index
            return
    activate_requested.emit()
