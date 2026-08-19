#!/usr/bin/env bash
# The only launcher. check_godot_launcher.sh fails on a direct godot invocation.
# LA_GODOT_TIMEOUT=<seconds> wraps the run; `timeout` cannot run a shell function.


# 1x1 at creation: macOS clamps an off-screen position back on, and _ready is too late to shrink.
LA_OFFSCREEN_POS="${LA_WIN_POS:-99999,99999}"
LA_OFFSCREEN_RES="${LA_RES:-1x1}"

la_godot() {
	local binary="${GODOT:-godot}"
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
