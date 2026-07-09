class_name LAAppExit
extends Node

## LAAppExit — the single, focused owner of process exit for the whole game.
##
## Why it exists: on macOS/Metal the ordinary `get_tree().quit()` path runs through
## `-[NSApplication terminate:]`, which posts NSApplicationWillTerminate. MoltenVK's
## termination observer then locks an already-destroyed recursive_mutex and aborts
## (SIGABRT, rc=134) — AFTER our clean shutdown (saves, dispose, SIM_REPORT) has fully
## finished. That teardown-order bug is engine/library-internal; we cannot patch MoltenVK.
##
## The fix is to take ownership of the exit: after the normal shutdown has flushed and one
## idle frame has passed (so any queued disk writes complete), terminate the process HARD
## and clean via the native `LAProcess.exit_now` (std::_Exit) — which flushes stdio, runs
## no C++ static destructors, and fires NO AppKit termination notification, so MoltenVK's
## observer never runs. The process leaves with the requested code (0) and the kernel
## reclaims all memory/GPU resources. This ONLY happens on a real quit, never mid-run.
##
## Registered as the `AppExit` autoload. Every quit call site routes here via `request()`.

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


## Static entry point usable from anywhere — including static contexts (pass any live node
## as `ctx`). Routes to the `AppExit` autoload; falls back to a plain `tree.quit()` when the
## autoload is absent (e.g. isolated unit tests), so nothing depends hard on this node.
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
	# Hard, clean exit that skips the MoltenVK NSApplication-terminate abort (rc 0). When the
	# native extension is unavailable (headless without it), fall back to a normal quit.
	if ClassDB.class_exists("LAProcess"):
		LAProcess.exit_now(code)
	elif tree != null:
		tree.quit(code)
