class_name LAAppQuit
extends RefCounted

## Quit through the AppExit autoload when the project registers one, else through the tree itself.


static func request(ctx: Node, code: int = 0) -> void:
	if ctx == null:
		return
	var tree: SceneTree = ctx.get_tree()
	if tree == null:
		return
	var inst: Node = tree.root.get_node_or_null("AppExit")
	if inst != null and inst.has_method("quit"):
		inst.call("quit", code)
	else:
		tree.quit(code)
