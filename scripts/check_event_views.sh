#!/usr/bin/env bash
# THE EVENT-VIEW HOST'S CONTRACT. Every registry record draws with an LAEventView naming its switch; a rung
# without a record's processes offers no switch, no view and no wiring for it; a switched-off kind draws
# nothing; each kind stands within its budget; a rock is drawn whether it precedes the render layer or
# follows it; the cyclone ring swirls about the local vertical, is not culled and is sized by its own cell.
# EXIT 0 held · 1 broken · 2 could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh"
. "$ROOT/scripts/lib_godot.sh"
require_tool rg

PROBE_REL="addons/local_agents/tests/gate_event_views.gd"
[ -f "$ROOT/$PROBE_REL" ] || {
	echo "check_event_views: MISSING $PROBE_REL — there is no contract to run." >&2; exit 2; }

probe="$(la_godot --headless --path "$ROOT" -s "res://$PROBE_REL" 2>&1)"
line="$(printf '%s\n' "$probe" | grep -m1 '^EVENT_VIEWS=')"
if [ -z "$line" ]; then
	echo "check_event_views: the probe published no EVENT_VIEWS line, so nothing was asked." >&2
	printf '%s\n' "$probe" | tail -20 >&2
	exit 2
fi
echo "$line"
fails="$(printf '%s' "$line" | rg -N -o -e '"failures":[0-9]+' | rg -N -o -e '[0-9]+')"
absent="$(printf '%s' "$line" | rg -N -o -e '"absent_seen":[0-9]+' | rg -N -o -e '[0-9]+')"
present="$(printf '%s' "$line" | rg -N -o -e '"present_seen":[0-9]+' | rg -N -o -e '[0-9]+')"
if [ -z "${fails:-}" ]; then
	echo "check_event_views: the probe published no verdict." >&2
	exit 2
fi
if [ "$fails" -ne 0 ]; then
	printf '%s\n' "$probe" | grep -v '^EVENT_VIEWS=' | tail -20 >&2
	exit 1
fi
if printf '%s\n' "$probe" | grep -qE '^(SCRIPT )?ERROR:'; then
	echo "check_event_views: the probe logged engine errors, so its verdict is not evidence." >&2
	printf '%s\n' "$probe" | grep -m4 -E '^(SCRIPT )?ERROR:' >&2
	exit 2
fi
# THE POSITIVE CONTROL: a walk that met no absent kind, or no present one, told nothing apart.
if [ "${absent:-0}" -eq 0 ] || [ "${present:-0}" -eq 0 ]; then
	echo "check_event_views: the rung walk met ${absent:-0} absent and ${present:-0} present kinds." >&2
	exit 2
fi
echo "check_event_views: OK"
