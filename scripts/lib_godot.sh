#!/usr/bin/env bash
# The only launcher. check_godot_launcher.sh fails on a direct godot invocation.
# LA_GODOT_TIMEOUT=<seconds> wraps the run; `timeout` cannot run a shell function.


# 1x1 at creation: macOS clamps an off-screen position back on, and _ready is too late to shrink.
LA_OFFSCREEN_POS="${LA_WIN_POS:-99999,99999}"
LA_OFFSCREEN_RES="${LA_RES:-1x1}"

# Godot sets its own activation policy to Regular at startup, over any plist, and activates itself when
# the main window shows. The extension sets the policy to Prohibited at CORE init under LA_OFFSCREEN;
# __CFBundleIdentifier must match the bundle id or Godot runs its unbundled activation hack. dyld resolves
# symlinks before bundle lookup, so the executable is a hard copy, moved into place whole.

la_agent_exe() {
	local real="$1"
	local app="${TMPDIR:-/tmp}/la-godot-agent/GodotAgent.app"
	local exe="$app/Contents/MacOS/godot"
	mkdir -p "$app/Contents/MacOS" || return 1
	cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>godot</string>
<key>CFBundleIdentifier</key><string>com.localagents.godot-agent</string>
<key>CFBundleName</key><string>GodotAgent</string>
<key>LSBackgroundOnly</key><true/>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
	if [ ! -x "$exe" ] || [ "$exe" -ot "$real" ]; then
		cp -f "$real" "$exe.$$" || return 1
		mv -f "$exe.$$" "$exe" || return 1
	fi
	echo "$exe"
}

la_godot() {
	local binary="${GODOT:-godot}"
	# NO FALLBACK TO THE REAL BINARY. Launching the ordinary Godot app is precisely the focus theft this
	# bundle exists to stop, so a bundle that cannot be built is a hard failure, not a quieter launch.
	if [ "$(uname)" = "Darwin" ]; then
		local real agent
		real="$(command -v "$binary" 2>/dev/null)" || { echo "la_godot: no $binary on PATH" >&2; return 127; }
		agent="$(la_agent_exe "$real")" || {
			echo "la_godot: could not build the non-activating GodotAgent bundle; refusing to launch a" >&2
			echo "           Godot that would steal the keyboard. Check ${TMPDIR:-/tmp}/la-godot-agent." >&2
			return 1
		}
		binary="$agent"
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
	# This branch creates a WINDOW, and the extension reads LA_OFFSCREEN at CORE to make it unfocusable.
	# Godot activates SystemUIServer and itself when the bundle id does not match this env var.
	LA_OFFSCREEN="${LA_OFFSCREEN:-1}" __CFBundleIdentifier="com.localagents.godot-agent" \
		command ${pre[@]+"${pre[@]}"} "$binary" \
		--position "$LA_OFFSCREEN_POS" --resolution "$LA_OFFSCREEN_RES" "$@"
}
