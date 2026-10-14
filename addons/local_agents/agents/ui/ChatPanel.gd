@tool
@icon("res://addons/local_agents/icons/local_agent_chat.svg")
extends PanelContainer
class_name LocalAgentChatPanel


signal prompt_submitted(text: String)
## Emitted when the model answers with non-empty text. Failures and empty replies are shown in the
## transcript but do not emit this.
signal reply_received(text: String)

const RequestSignals: GDScript = preload("res://addons/local_agents/runtime/RequestSignals.gd")
const Status: GDScript = preload("res://addons/local_agents/runtime/AgentStatus.gd")

@export_group("Wiring")

## The agent this panel drives. Leave empty to find a LocalAgent sibling or child automatically.
@export var agent: LocalAgent

@export_group("Behaviour")

## Send the prompt when Enter is pressed in the text box. With this off, only the Send button sends.
@export var send_on_enter: bool = true

## Text pasted in front of every prompt, on its own line. Use it for a standing instruction such as
## "Answer in one short sentence." Leave blank to send exactly what the user typed.
@export_multiline var prompt_prefix: String = ""

@export var auto_load_model: bool = true

@export var prompt_starters: Dictionary[String, String] = {}

@export_group("Presentation")

## Grey hint shown in the empty prompt box.
@export var placeholder_text: String = "Ask anything…"

## First line written into the transcript at startup, attributed to the agent. Blank = none.
@export_multiline var greeting: String = ""

## Show the readiness bar above the transcript. It reports what is wrong and what to do about it,
## so hide it only once you are confident the setup is good.
@export var show_status_bar: bool = true

## Echo what the user typed into the transcript. Off gives a one-sided "the agent narrates" feed.
@export var show_user_messages: bool = true

## How many lines the transcript keeps. Older lines are dropped off the top.
@export_range(20, 2000, 10, "suffix:lines") var max_transcript_lines: int = 200

## Colour of the "You" speaker tag.
@export_color_no_alpha var user_color: Color = Color(0.65, 0.78, 1.0)

## Colour of the agent's speaker tag.
@export_color_no_alpha var agent_color: Color = Color(0.85, 0.9, 0.95)

@onready var _transcript: RichTextLabel = get_node_or_null("%Transcript") as RichTextLabel
@onready var _prompt_input: LineEdit = get_node_or_null("%PromptInput") as LineEdit
@onready var _send_button: Button = get_node_or_null("%SendButton") as Button
@onready var _status_label: Label = get_node_or_null("%StatusLabel") as Label
@onready var _status_bar: Control = get_node_or_null("%StatusBar") as Control

var _lines: PackedStringArray = PackedStringArray()
var _busy: bool = false
var _stream_text: String = ""
var _generation: int = 0
var _request_agent: LocalAgent
var _completion: Callable
var _progress: Callable


func _ready() -> void:
    if not _has_scene_nodes():
        push_warning("LocalAgentChatPanel expects the node layout from ChatPanel.tscn; instance that scene instead of attaching this script by hand.")
        return
    # The editor guard comes FIRST. _apply_presentation() writes placeholder_text and `visible` on
    # child nodes, and both are serialised — running it in the editor turns them into saved instance
    # overrides in whatever scene this panel was dropped into.
    if Engine.is_editor_hint():
        update_configuration_warnings()
        return
    _apply_presentation()
    _create_prompt_starters()
    _prompt_input.text_submitted.connect(_on_text_submitted)
    _send_button.pressed.connect(_on_send_pressed)
    agent = _find_agent()
    if greeting.strip_edges() != "":
        _append(_agent_label(), greeting.strip_edges(), agent_color)
    refresh_status()


## Send `text` exactly as if the user had typed it. Public so a quest trigger, a proximity volume or
## another script can drive the panel without touching its widgets.
func send(text: String) -> void:
    if not _has_scene_nodes() or Engine.is_editor_hint():
        return
    var prompt: String = text.strip_edges()
    if prompt == "" or _busy:
        return

    var state: Dictionary = Status.check()
    if not _gating_blockers(state["blockers"]).is_empty():
        _status_label.text = String(state["next_step"])
        _update_input_state(false)
        return

    if agent == null:
        agent = _find_agent()
    if agent == null:
        _status_label.text = "No LocalAgent found. Assign one to this panel's Agent property."
        return

    prompt_submitted.emit(prompt)
    if show_user_messages:
        _append("You", prompt, user_color)
    _prompt_input.clear()
    _busy = true
    _update_input_state(true)
    refresh_status()      # so the status bar actually shows "Thinking..." while it is thinking

    var full_prompt: String = prompt
    if prompt_prefix.strip_edges() != "":
        full_prompt = "%s\n%s" % [prompt_prefix, prompt]
    _generation += 1
    if agent.think_async(full_prompt):
        _request_agent = agent
        _completion = Callable(self, "_on_think_completed").bind(_generation)
        _progress = Callable(self, "_on_reply_updated").bind(_generation)
        _request_agent.think_completed.connect(_completion)
        _request_agent.reply_updated.connect(_progress)
    else:
        _handle_result({"ok": false, "error": "request_not_started"})



## Empty the transcript, keeping the conversation the agent itself remembers.
func clear_transcript() -> void:
    _lines = PackedStringArray()
    if _transcript != null:
        _transcript.clear()


## Write a line into the transcript attributed to the agent, without asking the model anything.
func append_agent_text(text: String) -> void:
    _append(_agent_label(), text, agent_color)


## Re-read LocalAgentStatus and update the readiness bar and the enabled state of the input.
func refresh_status() -> void:
    if _status_label == null:
        return
    var state: Dictionary = Status.check()
    var blockers: PackedStringArray = _gating_blockers(state["blockers"])
    if _busy:
        _status_label.text = "Preparing your reply…"
    elif blockers.is_empty():
        _status_label.text = String(state["headline"])
    else:
        _status_label.text = "%s. %s" % [String(state["headline"]), String(state["next_step"])]
    _update_input_state(blockers.is_empty())


func _get_configuration_warnings() -> PackedStringArray:
    var out: PackedStringArray = Status.warnings_for({"extension": true, "autoload": true, "model": true})
    if not _has_scene_nodes():
        out.append("This script needs the node layout from ChatPanel.tscn (%Transcript, %PromptInput, %SendButton, %StatusLabel, %StatusBar). Instance that scene instead of attaching the script by hand.")
    elif agent == null and _find_agent() == null:
        out.append("No LocalAgent found. Set the Agent property, or put this panel beside (or above) a LocalAgent node.")
    return out


func _has_scene_nodes() -> bool:
    return _transcript != null and _prompt_input != null and _send_button != null and _status_label != null and _status_bar != null


func _apply_presentation() -> void:
    _prompt_input.placeholder_text = placeholder_text
    _status_bar.visible = show_status_bar


func _create_prompt_starters() -> void:
    var row: HFlowContainer = get_node_or_null("%Suggestions") as HFlowContainer
    if row == null:
        return
    row.visible = not prompt_starters.is_empty()
    for caption: String in prompt_starters:
        var button: Button = Button.new()
        button.text = caption
        button.theme_type_variation = &"PromptButton"
        button.tooltip_text = prompt_starters[caption]
        button.pressed.connect(Callable(self, "send").bind(prompt_starters[caption]))
        row.add_child(button)


func _on_send_pressed() -> void:
    send(_prompt_input.text)


func _on_text_submitted(text: String) -> void:
    if send_on_enter:
        send(text)


func _on_think_completed(result: Dictionary, generation: int) -> void:
    if not _busy or generation != _generation:
        return   # someone else is driving this agent; not our reply to render
    _handle_result(result)


func _on_reply_updated(text: String, generation: int) -> void:
    if _busy and generation == _generation and agent == _request_agent:
        _stream_text = text
        _status_label.text = "Generating reply…"
        _repaint()


func _disconnect_request() -> void:
    RequestSignals.disconnect_reply(_request_agent, _completion, _progress)
    _request_agent = null
    _completion = Callable()
    _progress = Callable()


func _exit_tree() -> void:
    _disconnect_request()
    _generation += 1


func _handle_result(result: Dictionary) -> void:
    if is_instance_valid(_request_agent) and agent != _request_agent:
        result = {"ok": false, "error": "agent_replaced"}
    _disconnect_request()
    _stream_text = ""
    _repaint()
    _busy = false
    var text: String = String(result.get("text", "")).strip_edges()
    if not bool(result.get("ok", true)):
        _append(_agent_label(), "(generation failed: %s)" % String(result.get("error", "unknown")), agent_color)
    elif text == "":
        _append(_agent_label(), "(no reply)", agent_color)
    else:
        _append(_agent_label(), text, agent_color)
        reply_received.emit(text)
    refresh_status()


# Blockers that actually stop this panel working. model_not_loaded is filtered out when
# auto_load_model is on, because send() resolves that one itself on the first prompt.
func _gating_blockers(blockers: PackedStringArray) -> PackedStringArray:
    var out: PackedStringArray = PackedStringArray()
    for entry in blockers:
        var code: String = String(entry)
        if auto_load_model and code == Status.BLOCK_MODEL_NOT_LOADED:
            continue
        out.append(code)
    return out


func _update_input_state(allowed: bool) -> void:
    if _prompt_input == null or _send_button == null:
        return
    var usable: bool = allowed and not _busy
    _prompt_input.editable = usable
    _send_button.disabled = not usable
    _send_button.text = "Thinking…" if _busy else "Send  →"
    var row: HFlowContainer = get_node_or_null("%Suggestions") as HFlowContainer
    if row != null:
        for button: Button in row.get_children():
            button.disabled = not usable


func _append(speaker: String, text: String, color: Color) -> void:
    if _transcript == null:
        return
    var line: String = "[color=#%s][b]%s[/b][/color]\n%s\n" % [color.to_html(false), _escape(speaker), _escape(text)]
    _lines.append(line)
    if _lines.size() > max_transcript_lines:
        _lines = _lines.slice(_lines.size() - max_transcript_lines)
        _repaint()
    else:
        _transcript.append_text(line + "\n")


func _repaint() -> void:
    _transcript.clear()
    for line in _lines:
        _transcript.append_text(String(line) + "\n")
    if _stream_text != "":
        _transcript.append_text("[color=#%s][b]%s[/b][/color]\n%s" % [agent_color.to_html(false), _escape(_agent_label()), _escape(_stream_text)])


# A model is free to answer with "[b]" or a stray "[", which RichTextLabel would eat as markup.
func _escape(text: String) -> String:
    return text.replace("[", "[lb]")


func _agent_label() -> String:
    if agent != null:
        return String(agent.name)
    return "Agent"


func _find_agent() -> LocalAgent:
    if agent != null:
        return agent
    var found: LocalAgent = _first_agent_under(self)
    if found != null:
        return found
    var parent: Node = get_parent()
    if parent == null:
        return null
    return _first_agent_under(parent)


func _first_agent_under(root: Node) -> LocalAgent:
    for child in root.get_children():
        if child is LocalAgent:
            return child as LocalAgent
    return null
