class_name LAQuietWindow
extends RefCounted

## An automated run's window is minimized and cannot take focus. macOS clamps a requested position back
## onto the screen, so off-view placement does not hide anything.

static func automated() -> bool:
	return OS.has_environment("LA_OFFSCREEN")


## MINIMIZED CRASHES: a minimized Metal window SIGBUSes in memmove about 125 frames in. So the window stays
## mapped and drawable, and is instead shrunk to one pixel in the screen's bottom-right corner, where it
## covers nothing, plus NO_FOCUS so it cannot take the keyboard.
static func apply(shrink: bool = true) -> void:
	if DisplayServer.get_name() == "headless":
		return
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS, true)
	if not shrink:
		return
	DisplayServer.window_set_size(Vector2i(1, 1))
	var r: Rect2i = DisplayServer.screen_get_usable_rect(DisplayServer.window_get_current_screen())
	DisplayServer.window_set_position(r.position + r.size - Vector2i(1, 1))


static func apply_if_automated(shrink: bool = true) -> void:
	if automated():
		apply(shrink)


static func state_line() -> String:
	var sz: Vector2i = DisplayServer.window_get_size()
	return 'LA_WINDOW_STATE={"w":%d,"h":%d,"no_focus":%s}' % [sz.x, sz.y,
		str(DisplayServer.window_get_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS)).to_lower()]
