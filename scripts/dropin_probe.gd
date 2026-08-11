extends SceneTree

## Test apparatus for scripts/check_dropin_scene.sh. This script is NOT part of the scene under test.
##
## The claim being checked is that a user can build a working quickstart out of nodes and inspector
## values, writing no GDScript at all. Something still has to observe the result, so this driver does
## the observing from outside: it loads the hand-authored scene, proves nothing inside it carries a
## script the user would have had to write, and then drives it through the same public entry point
## the Enter key uses (LocalAgentChatPanel.send).
##
## Arguments after `--`:
##   --scene=res://Quickstart.tscn   scene to load (required)
##   --prompt="..."                  send this through the ChatPanel and wait for a reply
##   --timeout=60                    seconds to wait for that reply
##
## Prints one DROPIN_GATE={...} line and exits non-zero on failure.
## (Explicit types only - project rule: no ':=' inferred typing.)

const ADDON_PREFIX: String = "res://addons/local_agents/"

var _scene_path: String = ""
var _prompt: String = ""
var _timeout: float = 60.0

var _root: Node = null
var _panel: Node = null
var _agent: Node = null

var _foreign_scripts: PackedStringArray = PackedStringArray()
var _reply: String = ""
var _reply_seen: bool = false
var _elapsed: float = 0.0
var _sent: bool = false
var _failure: String = ""


func _initialize() -> void:
	_parse_args()
	if _scene_path.is_empty():
		_fail("no --scene given")
		return

	var packed: PackedScene = load(_scene_path) as PackedScene
	if packed == null:
		_fail("scene failed to load: %s" % _scene_path)
		return

	_root = packed.instantiate()
	if _root == null:
		_fail("scene failed to instantiate: %s" % _scene_path)
		return
	get_root().add_child(_root)

	# The gate itself: every script reachable in this scene must belong to the addon. A script
	# anywhere else means the "zero lines of GDScript" claim is being propped up by a helper.
	_collect_foreign_scripts(_root)

	_panel = _find_by_method(_root, "send")
	_agent = _find_by_method(_root, "think_async")

	if _panel == null:
		_fail("no node exposing send() in the scene, so nothing implements the chat surface")
		return
	if _agent == null:
		_fail("no node exposing think_async() in the scene, so no agent was wired")
		return
	if _foreign_scripts.size() > 0:
		_fail("scene carries scripts outside the addon: %s" % ", ".join(_foreign_scripts))
		return

	if _prompt.is_empty():
		# Structure-only mode. The scene is well formed, which is all that can be checked without a
		# model installed, so report and quit on the next frame rather than waiting for a reply.
		return

	_panel.connect("reply_received", _on_reply)


func _process(delta: float) -> bool:
	if not _failure.is_empty():
		_report()
		return true

	if _prompt.is_empty():
		_report()
		return true

	_elapsed += delta

	# Send on the second frame so the panel's own _ready has run and it has resolved its agent.
	if not _sent and _elapsed > 0.1:
		_sent = true
		_panel.call("send", _prompt)

	if _reply_seen:
		_report()
		return true

	if _elapsed > _timeout:
		_failure = "no reply within %.0fs" % _timeout
		_report()
		return true

	return false


func _on_reply(text: String) -> void:
	_reply = text
	_reply_seen = true


func _parse_args() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	for arg in args:
		if arg.begins_with("--scene="):
			_scene_path = arg.substr(8)
		elif arg.begins_with("--prompt="):
			_prompt = arg.substr(9)
		elif arg.begins_with("--timeout="):
			_timeout = float(arg.substr(10))


# Walks the instantiated tree rather than the .tscn text, so a script pulled in by an instanced
# sub-scene is caught as well as one set directly on a node.
func _collect_foreign_scripts(node: Node) -> void:
	var script: Variant = node.get_script()
	if script != null and script is Resource:
		var path: String = (script as Resource).resource_path
		if not path.is_empty() and not path.begins_with(ADDON_PREFIX):
			_foreign_scripts.append("%s -> %s" % [node.name, path])
	for child in node.get_children():
		_collect_foreign_scripts(child)


func _find_by_method(node: Node, method: String) -> Node:
	if node.has_method(method):
		return node
	for child in node.get_children():
		var found: Node = _find_by_method(child, method)
		if found != null:
			return found
	return null


func _fail(reason: String) -> void:
	_failure = reason


func _report() -> void:
	# LocalAgentStatus is a static class_name, reachable directly once the addon is in the project.
	var state: Dictionary = LocalAgentStatus.check()
	var level: String = str(state.get("level", ""))
	var next_step: String = str(state.get("next_step", ""))
	var blockers: PackedStringArray = state.get("blockers", PackedStringArray()) as PackedStringArray

	var ok: bool = _failure.is_empty() and (_prompt.is_empty() or (_reply_seen and not _reply.strip_edges().is_empty()))

	var payload: Dictionary = {
		"ok": ok,
		"scene": _scene_path,
		"foreign_scripts": Array(_foreign_scripts),
		"panel": _panel != null,
		"agent": _agent != null,
		"prompted": not _prompt.is_empty(),
		"replied": _reply_seen,
		"reply_chars": _reply.strip_edges().length(),
		"status_level": level,
		"blockers": Array(blockers),
		"warnings": Array(state.get("warnings", PackedStringArray()) as PackedStringArray),
		"speech_ok": state.get("speech_ok", false),
		"extension_ok": state.get("extension_ok", false),
		"next_step": next_step,
		"failure": _failure,
	}
	print("DROPIN_GATE=%s" % JSON.stringify(payload))
	if not _reply.strip_edges().is_empty():
		print("DROPIN_REPLY=%s" % _reply.strip_edges())
	if not ok:
		quit(1)
	else:
		quit(0)
