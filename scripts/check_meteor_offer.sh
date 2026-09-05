#!/usr/bin/env bash
# A METEOR IS OFFERED ONLY TO A WORLD THAT CAN RECEIVE ITS IMPACT: the solved gravity that brings the
# rock down, the conduction that carries its impact heat out of the crater, and the transport that moves
# the rock it throws. Arm 1 walks the ladder aiming a rock at every rung. Arm 2 runs the bottom rung's
# own world with --auto-meteor: it must name the refusal, let no rock in, and offer no control for one.
# EXIT 0 refused where the processes are absent and received where they are · 1 not · 2 could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh"
. "$ROOT/scripts/lib_godot.sh"
require_tool rg
require_tool python3

PROBE_REL="addons/local_agents/tests/gate_meteor_offer.gd"
[ -f "$ROOT/$PROBE_REL" ] || {
	echo "check_meteor_offer: MISSING $PROBE_REL — there is no ladder walk to run." >&2; exit 2; }

fail=0

# --- ARM 1: the ladder ------------------------------------------------------------------------------
probe="$(la_godot --headless --path "$ROOT" -s "res://$PROBE_REL" 2>&1)"
offer="$(printf '%s\n' "$probe" | grep -m1 '^METEOR_OFFER=')"
if [ -z "$offer" ]; then
	echo "check_meteor_offer: the ladder walk published no METEOR_OFFER, so nothing was asked." >&2
	printf '%s\n' "$probe" | tail -20 >&2
	exit 2
fi
echo "$offer"
# A WALK THAT LOGGED ENGINE ERRORS MEASURED NOTHING, whatever it then printed.
if printf '%s\n' "$probe" | grep -qE '^(SCRIPT )?ERROR:'; then
	echo "check_meteor_offer: the ladder walk logged engine errors, so its verdict is not evidence." >&2
	printf '%s\n' "$probe" | grep -m4 -E '^(SCRIPT )?ERROR:' >&2
	exit 2
fi
fails="$(printf '%s' "$offer" | rg -N -o -e '"failures":[0-9]+' | rg -N -o -e '[0-9]+')"
first="$(printf '%s' "$offer" | rg -N -o -e '"first_offering":-?[0-9]+' | rg -N -o -e '\-?[0-9]+')"
if [ -z "${fails:-}" ] || [ -z "${first:-}" ]; then
	echo "check_meteor_offer: the ladder walk published no verdict." >&2
	exit 2
fi
if [ "$fails" -ne 0 ]; then
	printf '%s\n' "$probe" | grep -v '^METEOR_OFFER=' | tail -20 >&2
	echo "The offer and the world disagree: LAWorldOffers.has_impacts() is answered off LAProcessSet," >&2
	echo "and every path that lands a rock goes through LAMeteorImpacts.arrive()." >&2
	fail=1
fi
# The ladder walk's own refusal, said out loud where the world holds none of an impact's processes.
if ! printf '%s\n' "$probe" | grep -q '^METEOR_REFUSED='; then
	echo "FAIL  the ladder walk refused a rock at the bottom rung and never named the refusal." >&2
	fail=1
fi

# --- ARM 2: the bottom rung's own world -------------------------------------------------------------
LOG="$(mktemp "${TMPDIR:-/tmp}/la_meteor.XXXXXX")"
trap 'rm -f "$LOG"' EXIT
# The acceptance arm is the slice, and its box is sim_run.sh's; the whole body is the smoke test.
LA_SLICE_BOX="${LA_METEOR_SLICE:-$("$ROOT/scripts/sim_run.sh" --print-slice-box)}" \
LA_RUN_TIMEOUT="${LA_METEOR_TIMEOUT:-100}" "$ROOT/scripts/run_sim_offscreen.sh" --path "$ROOT" \
	addons/local_agents/game/VoxelWorld.tscn --fixed-fps 60 \
	-- --sandbox --planet-only --no-fauna --rung=0 --ui \
	"--run-frames=${LA_METEOR_FRAMES:-90}" --auto-meteor > "$LOG" 2>&1

if grep -qE '^(SCRIPT )?ERROR:|errored bytecode|Parameter "shader" is null' "$LOG"; then
	echo "check_meteor_offer: the rung-0 run logged engine errors, so nothing it printed is evidence." >&2
	grep -m4 -E '^(SCRIPT )?ERROR:|errored bytecode|Parameter "shader" is null' "$LOG" >&2
	exit 2
fi
report="$(grep -m1 '^SIM_REPORT=' "$LOG")"
if [ -z "$report" ]; then
	echo "check_meteor_offer: the rung-0 run published no SIM_REPORT, so nothing was counted." >&2
	tail -20 "$LOG" >&2
	exit 2
fi
# THE RUN HAS TO HAVE ASKED. --auto-meteor fires once the world is placed; if it never fired, the run
# proves nothing about a refusal and the silence below is not evidence.
marker="$(grep -m1 '^METEOR_REFUSED=' "$LOG")"
if [ -z "$marker" ]; then
	echo "FAIL  the rung-0 run never named a refusal: either --auto-meteor never asked for a rock, or a" >&2
	echo "  world with no gravity, no conduction and no rock transport took one silently." >&2
	fail=1
else
	echo "$marker"
	printf '%s' "$marker" | grep -q 'rung:"state"' || {
		echo "FAIL  the refusal names a rung this run is not: ${marker}" >&2
		fail=1
	}
	printf '%s' "$marker" | grep -q 'GravityPass.gd' || {
		echo "FAIL  the refusal does not name the absent gravity: ${marker}" >&2
		fail=1
	}
fi

meteors="$(printf '%s' "$report" | rg -N -o -e '"meteors": *[0-9]+' | rg -N -o -e '[0-9]+')"
if [ -z "${meteors:-}" ]; then
	echo "check_meteor_offer: the run published no meteor count, so nothing was measured." >&2
	exit 2
fi
[ "$meteors" -eq 0 ] || {
	echo "FAIL  rung 0 holds none of an impact's processes and ${meteors} rock(s) arrived anyway." >&2
	fail=1
}

# AND IT OFFERED NO CONTROL FOR ONE. A palette entry for a meteor in a world that refuses meteors is the
# HUD asking for a process the world does not contain.
palette="$(grep -m1 '^SPAWN_PALETTE=' "$LOG")"
if [ -z "$palette" ]; then
	echo "check_meteor_offer: the --ui run built no spawn palette, so its offer was never read." >&2
	exit 2
fi
echo "$palette"
printf '%s' "$palette" | grep -q '"impact":false' || {
	echo "FAIL  the palette offered its impact cluster in a world that refuses impacts: ${palette}" >&2
	fail=1
}
printf '%s' "$palette" | grep -q '"kinds":\[\]' || {
	echo "FAIL  the palette built a spawn button in a world with neither life nor impacts: ${palette}" >&2
	fail=1
}
printf '%s' "$palette" | grep -q '"panel":false' || {
	echo "FAIL  the palette panel stands with nothing in it: ${palette}" >&2
	fail=1
}

[ "$fail" -eq 0 ] || exit 1
echo "check_meteor_offer: OK (refused below rung ${first}, received at and above it)"
