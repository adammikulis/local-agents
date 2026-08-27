#!/usr/bin/env bash
# THE CONTROLS ENUMERATE THE PROCESS TABLE. LAProcessSetPanel draws one box per LAProcessSet record and
# keeps no list of its own, so adding a process to the table adds a control. This holds that both ways: a
# record with no control would be a process a player cannot turn off, and a control answering to no record
# would be a switch that does nothing.
# EXIT 0 every process has one control · 1 one does not · 2 could not run.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_godot.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_capture.sh"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-godot}"
command -v "$GODOT" >/dev/null 2>&1 || { echo "ERROR: godot not on PATH — a gate that cannot run FAILS." >&2; exit 2; }
[ -f "$REPO_ROOT/addons/local_agents/game/ui/ProcessSetPanel.gd" ] || {
  echo "ERROR: ProcessSetPanel.gd missing — there are no controls to check." >&2; exit 2; }

PROBE_REL="addons/local_agents/tests/gate_process_ui.gd"
[ -f "$REPO_ROOT/$PROBE_REL" ] || { echo "ERROR: MISSING $PROBE_REL." >&2; exit 2; }

if la_cap_dir >/dev/null; then
  out="$(la_headless process_ui)" || exit 2
else
  out="$(la_godot --headless --path "$REPO_ROOT" -s "res://$PROBE_REL" 2>&1)"
fi

line="$(printf '%s\n' "$out" | grep -m1 '^PROCESS_UI=')"
if [ -z "$line" ]; then
  echo "ERROR: the probe produced no PROCESS_UI line — refusing to report a pass." >&2
  printf '%s\n' "$out" | tail -20 >&2
  exit 2
fi
echo "$line"
fails="$(printf '%s' "$line" | grep -oE '"failures":[0-9]+' | grep -oE '[0-9]+$')"
[ -n "$fails" ] || { echo "ERROR: the probe published no failure count." >&2; exit 2; }
if [ "$fails" -ne 0 ]; then
  printf '%s\n' "$out" | grep -vE '^PROCESS_UI=' | tail -30 >&2
  echo
  echo "The controls and the process table disagree. LAProcessSetPanel builds itself from"
  echo "LAProcessSet.records(); a mismatch means something there is being listed by hand."
  exit 1
fi
echo "check_process_ui: OK"
