class_name LAAppExit
extends Node


var _quitting: bool = false


func _ready() -> void:
	# Take control of the window-close path: with auto-accept off, the engine hands us
	# NOTIFICATION_WM_CLOSE_REQUEST instead of auto-running the crashing terminate path.
	var tree: SceneTree = get_tree()
	if tree != null:
		tree.set_auto_accept_quit(false)


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		quit(0)


static func request(ctx: Node, code: int = 0) -> void:
	if ctx == null:
		return
	var tree: SceneTree = ctx.get_tree()
	if tree == null:
		return
	var inst: Node = tree.root.get_node_or_null("AppExit")
	if inst != null and inst.has_method("quit"):
		inst.quit(code)
	else:
		tree.quit(code)


## Perform the clean shutdown, then hard-exit. Idempotent (guards against re-entry).
func quit(code: int = 0) -> void:
	if _quitting:
		return
	_quitting = true
	var tree: SceneTree = get_tree()
	# Config/progress saves are already written synchronously at their point of change, and
	# SIM_REPORT has already printed; give one idle frame so any in-flight disk writes settle.
	if tree != null:
		await tree.process_frame
	if ClassDB.class_exists("LAProcess"):
		var proc: Object = ClassDB.instantiate("LAProcess")
		if proc != null and proc.has_method("exit_now"):
			proc.call("exit_now", code)
	if tree != null:
		tree.quit(code)
