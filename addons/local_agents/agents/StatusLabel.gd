@tool
@icon("res://addons/local_agents/icons/local_agent_status.svg")
extends Label
class_name LocalAgentStatusLabel

## A Label that answers "is Local Agents working?" without anyone writing a line of code.
##
## Drop it anywhere in a scene. It polls `LocalAgentStatus` and shows the headline, tinted green when
## everything is ready, yellow when something optional is missing (a Piper voice, the voxel backend)
## and red when generation cannot happen at all. With `show_next_step` on it also prints the one
## sentence that fixes the topmost problem, so a player or a designer is never left guessing.
##
## Marked @tool so the label previews the real status while you are building the scene; the polling
## timer only exists at run time, so nothing ticks inside the editor.
##
## (Explicit types only — project rule: no ':=' inferred typing.)

## Emitted when the level or the headline changes — connect it in the Node dock to show a "Fix setup"
## button only while something is wrong. `level` matches LocalAgentStatus.Level (0 READY, 1 DEGRADED,
## 2 BLOCKED).
signal status_changed(level: int, headline: String)

const Status: GDScript = preload("res://addons/local_agents/runtime/AgentStatus.gd")

@export_group("Content")

## Append the one-sentence fix for the topmost problem under the headline. Blocked setups become
## self-explanatory; turn it off for a compact one-line readout.
@export var show_next_step: bool = true

@export_group("Polling")

## Seconds between checks. The check is cheap, but it does touch the filesystem, so do not drive it
## faster than you need.
@export_range(0.25, 30.0, 0.25, "suffix:s") var refresh_interval: float = 2.0:
    set(value):
        refresh_interval = value
        if _timer != null:
            _timer.wait_time = maxf(0.25, refresh_interval)

@export_group("Colours")

## Text colour when everything needed to generate text is present.
@export_color_no_alpha var ready_color: Color = Color(0.45, 0.85, 0.5)

## Text colour when generation works but something optional does not.
@export_color_no_alpha var degraded_color: Color = Color(0.95, 0.8, 0.35)

## Text colour when generation cannot happen at all.
@export_color_no_alpha var blocked_color: Color = Color(0.95, 0.45, 0.45)

var _timer: Timer = null
var _last_level: int = -1
var _last_headline: String = ""


func _ready() -> void:
    # Editor: do nothing at all. refresh() assigns `text` and calls add_theme_color_override(),
    # and BOTH are serialised Label properties — painting the live status here would overwrite
    # whatever the scene author typed and bake the runtime state into their .tscn on the next save.
    # A placeholder is a much smaller lie than silently editing someone's scene.
    if Engine.is_editor_hint():
        return
    _timer = Timer.new()
    _timer.name = "StatusTimer"
    _timer.one_shot = false
    _timer.wait_time = maxf(0.25, refresh_interval)
    _timer.timeout.connect(refresh)
    add_child(_timer)
    _timer.start()
    refresh()


## Re-read LocalAgentStatus now and repaint. Public so a "Retry" button can force a check.
func refresh() -> void:
    var state: Dictionary = Status.check()
    var level: int = int(state["level"])
    var headline: String = String(state["headline"])
    var body: String = headline
    if show_next_step:
        var next_step: String = String(state["next_step"])
        if next_step != "":
            body = "%s\n%s" % [headline, next_step]
    text = body
    add_theme_color_override("font_color", _color_for(level))
    if level != _last_level or headline != _last_headline:
        _last_level = level
        _last_headline = headline
        status_changed.emit(level, headline)


func _color_for(level: int) -> Color:
    if level == Status.Level.BLOCKED:
        return blocked_color
    if level == Status.Level.DEGRADED:
        return degraded_color
    return ready_color
