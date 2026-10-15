#!/usr/bin/env bash
# The only launcher. check_godot_launcher.sh fails on a direct godot invocation.
# LA_GODOT_TIMEOUT=<seconds> wraps the run; `timeout` cannot run a shell function.

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_godot_lock.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_import.sh"


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
	# A UNIQUE STAGING NAME. `$$` is the same inside every subshell of one shell, so two concurrent
	# launches would copy the binary over each other and one would exec a half-written file.
	local stage
	if [ ! -x "$exe" ] || [ "$exe" -ot "$real" ]; then
		stage="$(mktemp "$app/Contents/MacOS/godot.XXXXXX")" || return 1
		cp -f "$real" "$stage" && chmod 755 "$stage" && mv -f "$stage" "$exe" || {
			rm -f "$stage"
			return 1
		}
	fi
	echo "$exe"
}

# THE MAINTAINER'S WINDOW. A second bundle with no background-only key, its own id, opened on the
# monitor at a real size with real audio. Only LA_SHOW_WINDOW=1 reaches it (scripts/show_demo.sh);
# check_godot_launcher.sh fails any automated script that sets it.
LA_SHOW_POS="${LA_WIN_POS:-120,80}"
LA_SHOW_RES="${LA_WINDOW_RES:-1600x1000}"
la_shown_exe() {
	local real="$1"
	local app="${TMPDIR:-/tmp}/la-godot-agent/GodotShown.app"
	local exe="$app/Contents/MacOS/godot"
	mkdir -p "$app/Contents/MacOS" || return 1
	cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>godot</string>
<key>CFBundleIdentifier</key><string>com.localagents.godot-shown</string>
<key>CFBundleName</key><string>GodotShown</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
	local stage
	if [ ! -x "$exe" ] || [ "$exe" -ot "$real" ]; then
		stage="$(mktemp "$app/Contents/MacOS/godot.XXXXXX")" || return 1
		cp -f "$real" "$stage" && chmod 755 "$stage" && mv -f "$stage" "$exe" || {
			rm -f "$stage"
			return 1
		}
	fi
	echo "$exe"
}

# Hash of the extension sources; build_extension.sh writes it beside the dylib.
la_extension_hash() {
	local ext="$1/addons/local_agents/gdextensions/localagents"
	(cd "$ext" && cat CMakeLists.txt cmake/deps/CMakeLists.txt $(ls src/* include/* | sort) | la_md5_stdin)
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
		if [ "${LA_SHOW_WINDOW:-}" = "1" ]; then
			agent="$(la_shown_exe "$real")" || { echo "la_godot: could not build the GodotShown bundle." >&2; return 1; }
		else
			agent="$(la_agent_exe "$real")" || {
				echo "la_godot: could not build the non-activating GodotAgent bundle; refusing to launch a" >&2
				echo "           Godot that would steal the keyboard. Check ${TMPDIR:-/tmp}/la-godot-agent." >&2
				return 1
			}
		fi
		binary="$agent"
	fi
	# The bundle id every launch runs under; the extension prohibits activation for exactly this id.
	export __CFBundleIdentifier="com.localagents.godot-agent"
	[ "${LA_SHOW_WINDOW:-}" = "1" ] && export __CFBundleIdentifier="com.localagents.godot-shown"
	la_extension_current "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || return 2
	# One line per engine launch. check_launch_count.sh counts them.
	if [ -n "${LA_LAUNCH_LOG:-}" ]; then
		printf '%s\n' "$*" >> "$LA_LAUNCH_LOG" 2>/dev/null || true
	fi
	local pre=()
	if [ -n "${LA_GODOT_TIMEOUT:-}" ]; then
		pre=(timeout "$LA_GODOT_TIMEOUT")
	fi
	# NO AUDIO DEVICE IN AN AUTOMATED RUN. CoreAudio refusing to start logs an engine error, and a run
	# that logged one publishes no numbers. The movie writer is the one launch that records sound.
	local audio=(--audio-driver Dummy)
	local a headless=0
	for a in "$@"; do
		[ "$a" = "--write-movie" ] && audio=()
		[ "$a" = "--headless" ] && headless=1
	done
	local held=0 rc=0
	if [ "$headless" -eq 0 ] || [ "${LA_CPU_VALIDATION:-0}" != "1" ]; then
		la_gpu_lock
		case $? in
			0) held=1 ;;
			2) ;;
			*) echo "la_godot: timed out waiting for the GPU lock; NO RUN HAPPENED." >&2; return 2 ;;
		esac
	fi
	if [ "$headless" -eq 1 ]; then
		command ${pre[@]+"${pre[@]}"} "$binary" ${audio[@]+"${audio[@]}"} "$@"
		rc=$?
	elif [ "${LA_SHOW_WINDOW:-}" = "1" ]; then
		# The maintainer's window: on the monitor, real size, real audio, focus allowed.
		# UNSET, not 0: the scene asks has_environment, and a set variable of any value shrinks the window.
		env -u LA_OFFSCREEN ${pre[@]+"${pre[@]}"} "$binary" \
			--position "$LA_SHOW_POS" --resolution "$LA_SHOW_RES" "$@"
		rc=$?
	else
		# This branch creates a WINDOW, and the extension reads LA_OFFSCREEN at CORE to make it unfocusable.
		LA_OFFSCREEN="${LA_OFFSCREEN:-1}" command ${pre[@]+"${pre[@]}"} "$binary" \
			${audio[@]+"${audio[@]}"} \
			--position "$LA_OFFSCREEN_POS" --resolution "$(la_window_res "$@")" "$@"
		rc=$?
	fi
	[ "$held" -eq 1 ] && la_gpu_unlock
	return $rc
}
