#!/usr/bin/env bash
# A MODULE SWITCHED OFF TAKES ITS WHOLE SUBTREE WITH IT. Nothing under its node draws or processes, a
# CanvasLayer under a plain Node and a node that runs through a pause included; switched on, each is back
# as it was; a root it shows while off is hidden again; one node answers to one switch, refused out loud;
# the test-mass module off holds no probe and releases none.
# EXIT 0 held · 1 broken · 2 could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh"
. "$ROOT/scripts/lib_godot.sh"
. "$ROOT/scripts/lib_capture.sh"
require_tool rg

PROBE_REL="addons/local_agents/tests/gate_ablate_modules.gd"
[ -f "$ROOT/$PROBE_REL" ] || { echo "check_ablate_modules: MISSING $PROBE_REL" >&2; exit 2; }

if la_cap_dir >/dev/null; then
	probe="$(la_headless ablate_modules)" || exit 2
else
	probe="$(la_godot --headless --path "$ROOT" -s "res://$PROBE_REL" 2>&1)"
fi
line="$(printf '%s\n' "$probe" | grep -m1 '^ABLATE_MODULES=')"
if [ -z "$line" ]; then
	echo "check_ablate_modules: the probe published no ABLATE_MODULES line, so nothing was asked." >&2
	printf '%s\n' "$probe" | tail -20 >&2
	exit 2
fi
echo "$line"
claims="$(printf '%s' "$line" | rg -N -o -e '"claims":[0-9]+' | rg -N -o -e '[0-9]+')"
fails="$(printf '%s' "$line" | rg -N -o -e '"failures":[0-9]+' | rg -N -o -e '[0-9]+')"
if [ -z "${claims:-}" ] || [ -z "${fails:-}" ] || [ "$claims" -eq 0 ]; then
	echo "check_ablate_modules: the probe published no verdict." >&2
	exit 2
fi
# THE TWO REFUSALS ARE THE CLAIM; any other engine error means the verdict is not evidence.
refused='LAAblate\.adopt\("probe_(nested|twice)"\)'
for name in nested twice; do
	printf '%s\n' "$probe" | grep -q "LAAblate.adopt(\"probe_$name\")" || {
		echo "check_ablate_modules: the second switch on one node (probe_$name) was taken without a word." >&2
		exit 1
	}
done
other="$(printf '%s\n' "$probe" | grep -E '^(SCRIPT )?ERROR:' | grep -vE "$refused")"
if [ -n "$other" ]; then
	echo "check_ablate_modules: the probe logged engine errors, so its verdict is not evidence." >&2
	printf '%s\n' "$other" | head -4 >&2
	exit 2
fi
if [ "$fails" -ne 0 ]; then
	printf '%s\n' "$probe" | grep -v '^ABLATE_MODULES=' | tail -20 >&2
	exit 1
fi
echo "check_ablate_modules: OK ($claims claims)"
