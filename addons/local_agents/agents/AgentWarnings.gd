@tool
extends RefCounted
class_name LocalAgentAgentWarnings


const Status: GDScript = preload("res://addons/local_agents/runtime/AgentStatus.gd")
const RuntimePaths: GDScript = preload("res://addons/local_agents/runtime/RuntimePaths.gd")


## Every reason this agent will not do what its inspector suggests, most fundamental first. An empty
## array means the node is good to go.
static func check(agent: Node) -> PackedStringArray:
    var out: PackedStringArray = PackedStringArray()
    if agent == null:
        return out
    var named_model: String = named_model_path(agent)
    var speaks: bool = bool(agent.get("speak_responses"))
    out.append_array(Status.warnings_for({
        "extension": true,
        "autoload": true,
        "model": named_model == "",
        "speech": speaks,
    }))
    if named_model != "" and not FileAccess.file_exists(RuntimePaths.normalize_path(named_model)):
        out.append("This agent's model file is not there:\n%s\nPick an installed .gguf, or clear the field to fall back to the project default." % named_model)
    if speaks:
        out.append_array(_speech_warnings(agent))
    if bool(agent.get("tick_enabled")) and float(agent.get("tick_interval")) <= 0.0:
        out.append("Tick Enabled is on but Tick Interval is 0, so this agent will never act. Set an interval in seconds (1.0 is a reasonable start).")
    return out


## The model this node names, ignoring the project-wide fallback: its own Model Path first, then its
## Model Profile's. "" when the node names neither and the project default applies.
static func named_model_path(agent: Node) -> String:
    var own: String = _string_property(agent, "model_path")
    if own != "":
        return own
    var profile: Resource = agent.get("model_profile") as Resource
    if profile != null:
        var profile_path: Variant = profile.get("model_path")
        if profile_path is String:
            return (profile_path as String).strip_edges()
    return ""


static func _speech_warnings(agent: Node) -> PackedStringArray:
    var out: PackedStringArray = PackedStringArray()
    var voice: String = _string_property(agent, "voice")
    if voice == "":
        out.append("Speak Responses is on but Voice is empty, so nothing will be said out loud. Put a Piper voice id in Voice (a folder or .onnx under addons/local_agents/voices).")
        return out
    var report: Dictionary = RuntimePaths.voice_asset_report(voice)
    if not bool(report.get("ok", false)):
        var candidates: PackedStringArray = PackedStringArray(report.get("candidates", PackedStringArray()))
        out.append("Voice \"%s\" was not found, so nothing will be said out loud.\nChecked: %s" % [voice, ", ".join(candidates)])
    return out


# agent.get() returns null for a property that does not exist, and String(null) is the literal
# "<null>" — so check the type instead of stringifying blindly.
static func _string_property(agent: Node, property: String) -> String:
    var value: Variant = agent.get(property)
    if value is String:
        return (value as String).strip_edges()
    return ""
