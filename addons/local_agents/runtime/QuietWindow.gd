class_name LAQuietWindow
extends RefCounted

## An automated run's window is minimized and cannot take focus. macOS clamps a requested position back
## onto the screen, so off-view placement does not hide anything.

static func automated() -> bool:
	return OS.has_environment("LA_OFFSCREEN")


static func apply(minimize: bool = true) -> void:
	if DisplayServer.get_name() == "headless":
		return
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS, true)
	if minimize:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_MINIMIZED)


static func apply_if_automated(minimize: bool = true) -> void:
	if automated():
		apply(minimize)


static func state_line() -> String:
	return 'LA_WINDOW_STATE={"mode":%d,"no_focus":%s}' % [
		DisplayServer.window_get_mode(),
		str(DisplayServer.window_get_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS)).to_lower()]
