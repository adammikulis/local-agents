#!/usr/bin/env bash
# The only launcher. check_godot_launcher.sh fails on a direct godot invocation.
# LA_GODOT_TIMEOUT=<seconds> wraps the run; `timeout` cannot run a shell function.


LA_OFFSCREEN_POS="${LA_WIN_POS:--10000,-10000}"
LA_OFFSCREEN_RES="${LA_RES:-640x400}"

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
