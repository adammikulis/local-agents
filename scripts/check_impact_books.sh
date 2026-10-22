#!/usr/bin/env bash
# AN IMPACT SPENDS ITS OWN KINETIC ENERGY AND NOTHING ELSE. Arm A partitions one impact energy over five
# decades of impactor size: heat + excavation + the ejecta's ballistic energy must equal it, and the
# ejecta must reach the surface at sqrt(g R). Arm B arcs parcels out of one cell of a graded grid: a
# parcel leaves at the speed it was given, in m/s, and its landing heat is sized in the kilograms it
# left its SOURCE cell with. EXIT 0 the books close · 1 they do not · 2 could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh"
. "$ROOT/scripts/lib_godot.sh"
require_tool rg

PROBE_REL="addons/local_agents/tests/gate_impact_books.gd"
[ -f "$ROOT/$PROBE_REL" ] || {
	echo "check_impact_books: MISSING $PROBE_REL — there is no partition to run." >&2; exit 2; }

probe="$(LA_CPU_VALIDATION=1 la_godot --headless --path "$ROOT" -s "res://$PROBE_REL" 2>&1)"
line="$(printf '%s\n' "$probe" | grep -m1 '^IMPACT_BOOKS=')"
if [ -z "$line" ]; then
	echo "check_impact_books: the probe published no IMPACT_BOOKS line, so nothing was measured." >&2
	printf '%s\n' "$probe" | tail -20 >&2
	exit 2
fi
echo "$line"
# A RUN THAT LOGGED ENGINE ERRORS MEASURED NOTHING, whatever it then printed.
if printf '%s\n' "$probe" | grep -qE '^(SCRIPT )?ERROR:'; then
	echo "check_impact_books: the probe logged engine errors, so its verdict is not evidence." >&2
	printf '%s\n' "$probe" | grep -m4 -E '^(SCRIPT )?ERROR:' >&2
	exit 2
fi
fails="$(printf '%s' "$line" | rg -N -o -e '"failures":[0-9]+' | rg -N -o -e '[0-9]+')"
if [ -z "${fails:-}" ]; then
	echo "check_impact_books: the probe published no verdict." >&2
	exit 2
fi
if [ "$fails" -ne 0 ]; then
	printf '%s\n' "$probe" | grep -v '^IMPACT_BOOKS=' | tail -20 >&2
	echo >&2
	echo "An impact's energy is ONE number. Whatever is thrown comes out of it, and a parcel has one mass:" >&2
	echo "the kilograms it was debited in at its source cell, not the amount its destination would weigh." >&2
	exit 1
fi

# THE POSITIVE CONTROL. Arm B tells source from destination only if the two cells differ; a probe that
# graded nothing would pass every sizing question by accident.
ratio="$(printf '%s' "$line" | rg -N -o -e '"unit_ratio":[0-9.]+' | rg -N -o -e '[0-9.]+')"
if [ -z "${ratio:-}" ] || awk -v r="$ratio" 'BEGIN{exit !(r <= 1.0001)}'; then
	echo "check_impact_books: the probe's two cells weigh a channel unit the same (ratio ${ratio:-none})," >&2
	echo "       so it could not have told a source-sized parcel from a destination-sized one." >&2
	exit 2
fi
echo "check_impact_books: OK"
