#!/usr/bin/env bash
# The only launcher. check_godot_launcher.sh fails on a direct godot invocation.
# LA_GODOT_TIMEOUT=<seconds> wraps the run; `timeout` cannot run a shell function.


# 1x1 AT CREATION. macOS clamps an off-screen position back on, so a window with pixels in it lands on
# the user's monitor and _ready is too late to shrink it. A screenshot and a perf frame are read off a
# SubViewport, so nothing else needs a window with pixels.
LA_OFFSCREEN_POS="${LA_WIN_POS:-99999,99999}"

# THE ONE EXEMPTION, AND IT IS THE ENGINE'S: Godot's movie maker records the ROOT viewport, so footage
# needs a window the size of the footage. No other run may ask.
la_window_res() {
	local a
	for a in "$@"; do
		if [ "$a" = "--write-movie" ]; then printf '%s' "${LA_MOVIE_RES:-1280x720}"; return; fi
	done
	printf '1x1'
}

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

# Hash of the extension sources; build_extension.sh writes it beside the dylib.
la_extension_hash() {
	local ext="$1/addons/local_agents/gdextensions/localagents"
	(cd "$ext" && cat CMakeLists.txt $(ls src/* include/* | sort) | md5 -q)
}

# A dylib built from other sources is a stale binary: refuse, never run it.
la_extension_current() {
	local ext="$1/addons/local_agents/gdextensions/localagents"
	[ -d "$ext/src" ] || return 0
	local want have
	want="$(la_extension_hash "$1")"
	have="$(cat "$ext/bin/SOURCE_HASH" 2>/dev/null)"
	if [ "$want" != "$have" ]; then
		echo "la_godot: $ext/bin was built from other sources (SOURCE_HASH ${have:-missing}, sources $want)." >&2
		echo "          Rebuild: $ext/scripts/build_extension.sh --platform macos" >&2
		return 1
	fi
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
	# The bundle id every launch runs under; the extension prohibits activation for exactly this id.
	export __CFBundleIdentifier="com.localagents.godot-agent"
	la_extension_current "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || return 2
	# One line per engine launch. check_launch_count.sh counts them.
	if [ -n "${LA_LAUNCH_LOG:-}" ]; then
		printf '%s\n' "$*" >> "$LA_LAUNCH_LOG" 2>/dev/null || true
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
	LA_OFFSCREEN="${LA_OFFSCREEN:-1}" command ${pre[@]+"${pre[@]}"} "$binary" \
		--position "$LA_OFFSCREEN_POS" --resolution "$(la_window_res "$@")" "$@"
}
