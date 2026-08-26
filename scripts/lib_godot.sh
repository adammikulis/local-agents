#!/usr/bin/env bash
# The only launcher. check_godot_launcher.sh fails on a direct godot invocation.
# LA_GODOT_TIMEOUT=<seconds> wraps the run; `timeout` cannot run a shell function.


# 1x1 at creation: macOS clamps an off-screen position back on, and _ready is too late to shrink.
LA_OFFSCREEN_POS="${LA_WIN_POS:-99999,99999}"
LA_OFFSCREEN_RES="${LA_RES:-1x1}"

# macOS activates every launched GUI app and its keystrokes go nowhere; an LSUIElement bundle never
# activates, so nothing here may activate an app back - `osascript ... to activate` drags the user out of
# a fullscreen Space. dyld resolves symlinks before bundle lookup, so the executable is a hard copy,
# cached by inode-checked mtime.
la_agent_exe() {
	local real="$1"
	local app="${TMPDIR:-/tmp}/la-godot-agent/GodotAgent.app"
	local exe="$app/Contents/MacOS/godot"
	if [ ! -x "$exe" ] || [ "$exe" -ot "$real" ]; then
		mkdir -p "$app/Contents/MacOS"
		cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>godot</string>
<key>CFBundleIdentifier</key><string>com.localagents.godot-agent</string>
<key>CFBundleName</key><string>GodotAgent</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
		cp -f "$real" "$exe" || { echo "$real"; return; }
	fi
	echo "$exe"
}

la_godot() {
	local binary="${GODOT:-godot}"
	if [ "$(uname)" = "Darwin" ]; then
		local real
		real="$(command -v "$binary" 2>/dev/null)" && binary="$(la_agent_exe "$real")"
	fi
	local pre=()
	if [ -n "${LA_GODOT_TIMEOUT:-}" ]; then
		pre=(timeout "$LA_GODOT_TIMEOUT")
	fi
	local a
	for a in "$@"; do
		if [ "$a" = "--headless" ]; then
			command ${pre[@]+"${pre[@]}"} "$binary" "$@"
			return $?
		fi
	done
	command ${pre[@]+"${pre[@]}"} "$binary" \
		--position "$LA_OFFSCREEN_POS" --resolution "$LA_OFFSCREEN_RES" "$@"
}
