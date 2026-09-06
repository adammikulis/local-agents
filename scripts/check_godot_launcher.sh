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
# the launch flags can. A window with pixels in it lands on the user's monitor, because macOS clamps the
# off-screen position back on. 1x1 is the only size, with no override: a screenshot is read off a
# SubViewport, so no run has a reason to ask for a bigger one.
rg -q -e "printf '1x1'" "$LIB" || {
	echo "FAIL  scripts/lib_godot.sh no longer creates the window at 1x1, so a run can put a real" >&2
	echo "      window on the user's monitor before any script can shrink it." >&2
	launcher_fail=1
}
rg -q -e 'la_window_res "\$@"' "$LIB" || {
	echo "FAIL  scripts/lib_godot.sh does not size the window through la_window_res, so the movie" >&2
	echo "      exemption is not the only way to a window with pixels in it." >&2
	launcher_fail=1
}
# NO AUDIO DEVICE IN AN AUTOMATED RUN. CoreAudio refusing to start logs an engine error, and sim_run
# withholds every number from a run that logged one. Only the movie writer records sound.
rg -q -e 'audio=\(--audio-driver Dummy\)' "$LIB" || {
	echo "FAIL  scripts/lib_godot.sh does not force the Dummy audio driver, so an automated run opens a" >&2
	echo "      real audio device and one CoreAudio failure withholds the run's numbers." >&2
	launcher_fail=1
}
# ONE GPU, ONE ENGINE. A rig probe and a headless batch each make a RenderingDevice, so the lock belongs
# to the launch; without it several lanes share one GPU and a sim run dies on Godot's fence wait.
rg -q -e 'la_gpu_lock' "$LIB" || {
	echo "FAIL  scripts/lib_godot.sh launches without taking the machine-wide GPU lock." >&2
	launcher_fail=1
}
# THE SHOWN WINDOW IS THE MAINTAINER'S ALONE: only show_demo.sh may set LA_SHOW_WINDOW.
shown_over="$(rg -n --no-heading -g '*.sh' -g '!show_demo.sh' -g '!lib_godot.sh' -g '!check_godot_launcher.sh' \
	-e 'LA_SHOW_WINDOW=1' "$ROOT/scripts" "$ROOT/addons" 2>/dev/null || true)"
if [ -n "$shown_over" ]; then
	echo "FAIL  an automated script asks for the maintainer's visible window:" >&2
	printf '%s\n' "$shown_over" >&2
	launcher_fail=1
fi
lock_over="$(rg -n --no-heading -g '*.sh' -g '!check_godot_launcher.sh' -g '!lib_godot_lock.sh' \
	-e 'la_sim_gpu\.lock' "$ROOT/scripts" 2>/dev/null || true)"
if [ -n "$lock_over" ]; then
	printf '%s\n' "$lock_over" >&2
	echo "FAIL  the line(s) above name the GPU lock outside lib_godot_lock.sh, which declares it." >&2
	launcher_fail=1
fi
res_over="$(rg -n --no-heading -g '*.sh' -g '!check_godot_launcher.sh' -g '!lib_godot.sh' \
	-e '\bLA_RES\b' -e '--resolution' "$ROOT/scripts" 2>/dev/null || true)"
if [ -n "$res_over" ]; then
	printf '%s\n' "$res_over" >&2
	echo "" >&2
	echo "FAIL  the line(s) above size the window from outside lib_godot.sh. A second size is a second" >&2
	echo "      chance to put a visible window on the user's screen; --shoot draws into a SubViewport." >&2
	launcher_fail=1
fi

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

# A LANE MAY NOT KILL ANOTHER LANE'S RUN. Every lane's sim is the same binary, so pkill/killall by
# program name reaches runs this tree does not own, and removing the lock hands one GPU to two runs.
kills="$(rg -n --no-heading -g '*.sh' -g '!check_godot_launcher.sh' \
	-e '(^|[^-[:alnum:]_])(pkill|killall)[[:space:]]' -e 'rm[[:space:]].*la_sim_gpu\.lock' "$ROOT/scripts" 2>/dev/null \
	| grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)"
if [ -n "$kills" ]; then
	printf '%s\n' "$kills" >&2
	echo "" >&2
	echo "FAIL  the line(s) above kill by program name or unlink the GPU lock. Both reach runs this tree" >&2
	echo "      does not own. Kill the PID you launched, and let the lock's holder release it." >&2
	launcher_fail=1
fi

# NOTHING MAY ACTIVATE AN APP BACK: a stale "front app" re-activated after a run is a second theft.
if rg -q -g '!check_godot_launcher.sh' 'tell application .* to activate' "$ROOT/scripts"; then
	echo "FAIL  a script under scripts/ activates an application; delete it." >&2
	launcher_fail=1
fi
# Godot sets the activation policy to Regular at startup, over the plist. The extension must set it to
# Prohibited at CORE init, and the bundle id env must match or Godot runs its unbundled activation hack.
EXT="$ROOT/addons/local_agents/gdextensions/localagents"
rg -q 'NSApplicationActivationPolicyProhibited' "$EXT/src/LANoActivation.mm" 2>/dev/null || {
	echo "FAIL  $EXT/src/LANoActivation.mm does not prohibit activation." >&2; launcher_fail=1; }
rg -q 'la_prohibit_activation\(\)' "$EXT/src/LocalAgentsRegister.cpp" || {
	echo "FAIL  LocalAgentsRegister.cpp never calls la_prohibit_activation()." >&2; launcher_fail=1; }
rg -q 'export __CFBundleIdentifier="com\.localagents\.godot-agent"' "$LIB" || {
	echo "FAIL  $LIB does not set __CFBundleIdentifier to the bundle id for every launch." >&2; launcher_fail=1; }
rg -q 'la_extension_current .* \|\| return' "$LIB" || {
	echo "FAIL  $LIB launches a bin without checking it was built from the current sources." >&2; launcher_fail=1; }
rg -q 'write_source_hash$' "$EXT/scripts/build_extension.sh" || {
	echo "FAIL  build_extension.sh does not write bin/SOURCE_HASH." >&2; launcher_fail=1; }
rg -q 'isEqualToString:@"com\.localagents\.godot-agent"' "$EXT/src/LANoActivation.mm" || {
	echo "FAIL  LANoActivation.mm does not key the prohibition on the agent bundle id." >&2; launcher_fail=1; }

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
