#!/usr/bin/env bash
# NAVIGATION IS FLOWN, NOT STEPPED. The camera rig is driven with a synthetic stick: no frame moves its
# speed past what its response time constant allows, cruise speed at a declared height lands in that
# height's band, a released stick coasts to rest inside five time constants, the aim eases as the
# velocity does, and one press of the framing turns onto the simulated box and fits its footprint.
# EXIT 0 the drone flies · 1 it does not · 2 could not run.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_godot.sh"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-godot}"
command -v "$GODOT" >/dev/null 2>&1 || { echo "ERROR: godot not on PATH — a gate that cannot run FAILS." >&2; exit 2; }

PROBE_REL="addons/local_agents/tests/gate_fly_nav.gd"
[ -f "$REPO_ROOT/$PROBE_REL" ] || { echo "ERROR: MISSING $PROBE_REL." >&2; exit 2; }

out="$(la_godot --headless --path "$REPO_ROOT" -s "res://$PROBE_REL" 2>&1)" || true

line="$(printf '%s\n' "$out" | grep -m1 '^FLY_NAV=')"
if [ -z "$line" ]; then
  echo "ERROR: the probe produced no FLY_NAV line — refusing to report a pass." >&2
  printf '%s\n' "$out" | tail -20 >&2
  exit 2
fi
echo "$line"
fails="$(printf '%s' "$line" | grep -oE '"failures":[0-9]+' | grep -oE '[0-9]+$')"
[ -n "$fails" ] || { echo "ERROR: the probe published no failure count." >&2; exit 2; }
if [ "$fails" -ne 0 ]; then
  printf '%s\n' "$out" | grep -vE '^FLY_NAV=' | tail -30 >&2
  echo
  echo "The camera does not fly. Velocity eases toward the commanded one over one declared time"
  echo "constant, cruise speed follows the eye's height over the ground under it, and the framing"
  echo "turns and backs off rather than placing the eye."
  exit 1
fi
echo "check_fly_nav: OK"
