#!/usr/bin/env bash
# Every godot launch goes through la_godot, so exactly one place decides where the window lands.
# EXIT 0 clean · 1 a direct launch · 2 the gate could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh"
require_tool rg
LIB="$ROOT/scripts/lib_godot.sh"
[ -f "$LIB" ] || { echo "check_godot_launcher: MISSING $LIB" >&2; exit 2; }
grep -q '"\$binary"' "$LIB" || { echo "check_godot_launcher: $LIB launches nothing." >&2; exit 2; }

launcher_fail=0
# THE WINDOW IS CREATED BEFORE ANY SCRIPT RUNS, so QuietWindow.apply() cannot stop it appearing — only
# the launch flags can. A default resolution with pixels in it puts a real window on the user's monitor,
# because macOS clamps the off-screen position back on.
res_def="$(rg -N -o -e 'LA_OFFSCREEN_RES="\$\{LA_RES:-[^}]*\}"' "$ROOT/scripts/lib_godot.sh" | head -1)"
case "$res_def" in
	*:-1x1\}*) ;;
	"") echo "FAIL  scripts/lib_godot.sh no longer defaults LA_OFFSCREEN_RES; a window can be created" >&2
	    echo "      at any size." >&2; launcher_fail=1 ;;
	*)  echo "FAIL  scripts/lib_godot.sh creates the window at ${res_def#*:-} rather than 1x1, so it" >&2
	    echo "      user's monitor before any script can shrink it." >&2; launcher_fail=1 ;;
esac

# ACTIVATION IS NOT FOCUS. `no_focus` governs the window; macOS ACTIVATES the whole app on launch and
# yanks the user out of their Space regardless. Only a background-only bundle cannot be activated, and
# LSUIElement alone does not do it — it hides the Dock icon and still permits activation.
if ! rg -q '<key>LSBackgroundOnly</key><true/>' "$LIB"; then
	echo "FAIL  scripts/lib_godot.sh's agent bundle does not declare LSBackgroundOnly, so macOS may" >&2
	echo "      activate the launched Godot and steal the user's keyboard and Space." >&2
	launcher_fail=1
fi

# NO FALLBACK TO THE REAL BINARY. Launching the ordinary Godot app is the exact theft the bundle exists
# to prevent, so a bundle that cannot be built must fail the launch, never quietly take the other path.
if rg -q 'cp -f "\$real" "\$exe" \|\| \{ echo "\$real"' "$LIB"; then
	echo "FAIL  scripts/lib_godot.sh falls back to the real godot binary when the non-activating bundle" >&2
	echo "      cannot be built. That fallback IS the focus theft; a launch that cannot be quiet must fail." >&2
	launcher_fail=1
fi

# A COMMIT MAY NOT LAUNCH A SIM. The GPU gates each open a real window and take focus; they belong to
# integrate.sh and CI, which lint the staged merge before anything lands.
HOOK="$ROOT/scripts/githooks/pre-commit"
if [ -f "$HOOK" ] && rg -q 'agent_harness\.sh" lint' "$HOOK"; then
	rg -q 'LA_NO_GPU=1 "\$ROOT/scripts/agent_harness\.sh" lint' "$HOOK" || {
		echo "FAIL  $HOOK runs lint without LA_NO_GPU=1, so every commit launches the GPU gates and" >&2
		echo "      pops a Godot window onto the user's monitor." >&2
		launcher_fail=1
	}
fi

[ "$launcher_fail" -eq 0 ] || exit 1

SCAN="${1:-$ROOT/scripts}"
hits="$(rg -n --no-heading -g '*.sh' -g '!lib_godot.sh' -g '!check_godot_launcher.sh' \
	'(^|[^-[:alnum:]_/."])(\$GODOT|"\$GODOT"|godot)[[:space:]]+-' "$SCAN" 2>/dev/null \
	| grep -vE 'command -v|require_tool|which |echo |printf |^[^:]+:[0-9]+:[[:space:]]*#' || true)"

if [ -n "$hits" ]; then
	printf '%s\n' "$hits" >&2
	echo "" >&2
	echo "FAIL  the line(s) above launch godot directly. Source scripts/lib_godot.sh and call la_godot:" >&2
	echo "      a second launch path is a second place to forget --position, and the window lands on the" >&2
	echo "      user's screen. create_local_rendering_device() is null under --headless, so a GPU run" >&2
	echo "      opens a real window and off-view is the only thing keeping it out of the way." >&2
	exit 1
fi
echo "check_godot_launcher: OK (every launch goes through la_godot)"
