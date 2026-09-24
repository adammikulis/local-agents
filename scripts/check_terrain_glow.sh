#!/usr/bin/env bash
# THE GROUND GLOWS AT ITS OWN TEMPERATURE, IN THE SUNLIT UNIT. The terrain shader is drawn on the device over
# leaves of known temperature, lit by nothing, into a float target (tests/gate_terrain_emission.gd): each
# leaf emits Planck x (1 - albedo) over a white Lambertian surface under the star's full beam. `field`
# turns and displaces the body over a graded grid instead, and each pixel must read its own leaf.
# EXIT 0 held · 1 broken · 2 could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh"
ARM="${1:-glow}"
NAME="check_terrain_$ARM"
PROBE_REL="addons/local_agents/tests/gate_terrain_emission.gd"
[ -f "$ROOT/$PROBE_REL" ] || { echo "$NAME: MISSING $PROBE_REL." >&2; exit 2; }

out="$(LA_RUN_TIMEOUT="${LA_EMISSION_TIMEOUT:-60}" "$ROOT/scripts/run_sim_offscreen.sh" --path "$ROOT" \
	-s "res://$PROBE_REL" -- "--arm=$ARM" 2>&1)"
rc=$?
if printf '%s\n' "$out" | grep -qE 'SHADER ERROR|Shader compilation failed'; then
	printf '%s\n' "$out" | grep -m4 -E 'SHADER ERROR|Shader compilation failed|\.gdshader' >&2
	echo "$NAME: the terrain shader does not compile, so the ground draws nothing it was asked to." >&2
	exit 1
fi
line="$(printf '%s\n' "$out" | grep -m1 '^TERRAIN_EMISSION=')"
if [ -z "$line" ] || printf '%s' "$line" | grep -q '"error"'; then
	echo "$NAME: the probe measured nothing (run exit $rc)." >&2
	printf '%s\n' "${line:-$(printf '%s\n' "$out" | tail -20)}" >&2
	exit 2
fi
echo "$line"
fails="$(printf '%s' "$line" | sed -n 's/.*"failures":\([0-9][0-9]*\).*/\1/p')"
case "$fails" in "" | *[!0-9]*) echo "$NAME: the probe published no failure count." >&2; exit 2 ;; esac
if [ "$fails" -ne 0 ]; then
	printf '%s\n' "$out" | grep -m3 '^TERRAIN_EMISSION: ' >&2
	exit 1
fi
echo "$NAME: OK"
