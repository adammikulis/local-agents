#!/usr/bin/env bash
# EVERY PROCESS BELONGS TO A RUNG. A transport row, reduce row, reaction module or pass that no rung in
# LAProcessSet names is a process nobody decided the world contains — it would silently run at every rung
# or at none. The same check reads the other way: a row assigned BELOW the pass that allocates what it
# reads makes the smaller world reduce a buffer that is not there.
# EXIT 0 every process is placed · 1 one is not · 2 could not run.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_godot.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_capture.sh"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-godot}"
command -v "$GODOT" >/dev/null 2>&1 || { echo "ERROR: godot not on PATH — a gate that cannot run FAILS." >&2; exit 2; }
[ -f "$REPO_ROOT/addons/local_agents/sim/material/ProcessSet.gd" ] || {
  echo "ERROR: ProcessSet.gd missing — there is no ladder to check." >&2; exit 2; }

PROBE_REL="addons/local_agents/tests/gate_process_set.gd"
[ -f "$REPO_ROOT/$PROBE_REL" ] || { echo "ERROR: MISSING $PROBE_REL." >&2; exit 2; }

if la_cap_dir >/dev/null; then
  out="$(la_headless process_set)" || exit 2
else
  out="$(la_godot --headless --path "$REPO_ROOT" -s "res://$PROBE_REL" 2>&1)"
fi

line="$(printf '%s\n' "$out" | grep -m1 '^PROCESS_SET=')"
if [ -z "$line" ]; then
  echo "ERROR: the probe produced no PROCESS_SET line — refusing to report a pass." >&2
  printf '%s\n' "$out" | tail -20 >&2
  exit 2
fi
echo "$line"
fails="$(printf '%s' "$line" | grep -oE '"failures":[0-9]+' | grep -oE '[0-9]+$')"
[ -n "$fails" ] || { echo "ERROR: the probe published no failure count." >&2; exit 2; }
if [ "$fails" -ne 0 ]; then
  printf '%s\n' "$out" | grep -vE '^PROCESS_SET=' | tail -30 >&2
  echo
  echo "A process is in no rung, in two, or in one that does not allocate what it reads. Place it in"
  echo "LAProcessSet.rungs(): a rung is the smallest world in which that process is physically complete."
  exit 1
fi
echo "check_process_set: OK"
