#!/usr/bin/env bash
# THE BAKED WORLD IS THE SEEDED WORLD. A run that loads the bake must be handed the same planet the run
# that wrote it seeded: the same seal manifest, the same declared creations, nothing created after the
# seal, the same conservation stock on the sealing step, and the same body measured off the matter.
#
# Four arms at the rung the sandbox declares, so this reads a run that completes:
#   K  the key covers the seed's own source: edit a line of it and the content address moves
#   A  a guaranteed miss: seeds the world and writes the bake
#   B  a hit: loads it. Every compared row must equal A's, and world_seal_origin must say "restored"
#   C  the positive control: one channel of the bake is scaled, and B's comparison must SEE it
# EXIT 0 the bake is the seeded world · 1 it is not, or the comparison is blind · 2 could not run.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
. "$SCRIPT_DIR/lib_godot.sh"
. "$SCRIPT_DIR/lib_require.sh"
require_tool python3

RUNG="${LA_SEAL_RUNG:-2}"
FRAMES="${LA_SEAL_FRAMES:-6}"
SEED="${LA_SEAL_SEED:-4242}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/la_seal_cache.XXXXXX")" || {
	echo "check_seal_cache: no writable temp directory." >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT

probe() {  # probe <mode> [channel]
	LA_GODOT_TIMEOUT=60 la_godot --headless --path "$ROOT" -s "res://scripts/seal_cache_probe.gd" -- "$@"
}

# A PHYSICS VERDICT IS NOT A FAILED RUN. 122/123/126 are run_sim_offscreen's readings off a run that
# completed and published its report; this gate compares two such reports and owns none of those rows.
# A run that published nothing is caught where the reports are parsed.
arm() {  # arm <name>
	LA_SEAL_KEY="seal-cache-gate" "$SCRIPT_DIR/sim_run.sh" --path "$ROOT" --frames "$FRAMES" \
		--seed "$SEED" --rung "$RUNG" --raw > "$WORK/$1.json" 2> "$WORK/$1.err"
	case "$?" in
		0|122|123|126) return 0 ;;
		*) return 1 ;;
	esac
}

# ARM K, BEFORE ANY ENGINE RUNS. The bake is content-addressed, so the address must move when the code
# that seeds the world does. Its own bytes are put back from $WORK, never from git: a lane's uncommitted
# work is not this gate's to discard.
SEED_SRC="$ROOT/addons/local_agents/sim/material/MaterialFieldSphereStep3D.gd"
[ -f "$SEED_SRC" ] || { echo "check_seal_cache: MISSING ${SEED_SRC#"$ROOT"/}" >&2; exit 2; }
key_now() {
	"$SCRIPT_DIR/cache_key.sh" bake --path "$ROOT" "seed=$SEED" "rung=$RUNG" \
		"full=0" "fauna=0" "slice=0" "box=" 2>/dev/null
}
cp "$SEED_SRC" "$WORK/seed_src.orig" || { echo "check_seal_cache: cannot copy the seed source." >&2; exit 2; }
KEY_BEFORE="$(key_now)"
printf '\n' >> "$SEED_SRC"
KEY_AFTER="$(key_now)"
cp "$WORK/seed_src.orig" "$SEED_SRC"
KEY_BACK="$(key_now)"
{ [ -n "$KEY_BEFORE" ] && [ -n "$KEY_AFTER" ]; } || {
	echo "check_seal_cache: no content key describes this tree, so no bake can be addressed." >&2; exit 2; }
[ "$KEY_BEFORE" != "$KEY_AFTER" ] || {
	echo "check_seal_cache: editing the seed's own source did not move the bake's content address, so a" >&2
	echo "                  world baked by older seed code is served to newer code as if it were fresh." >&2
	exit 1
}
[ "$KEY_BEFORE" = "$KEY_BACK" ] || {
	echo "check_seal_cache: the key did not return to its own value, so it reads something other than" >&2
	echo "                  the tree's content and no bake is addressable at all." >&2
	exit 1
}

probe --clear > "$WORK/clear.log" 2>&1 || { echo "check_seal_cache: the bake store could not be cleared." >&2
	tail -5 "$WORK/clear.log" >&2; exit 2; }

arm seeded || { echo "check_seal_cache: the seeding arm did not report (exit $?). Nothing to compare." >&2
	tail -5 "$WORK/seeded.err" >&2; exit 2; }
arm restored || { echo "check_seal_cache: the loading arm did not report (exit $?)." >&2
	tail -5 "$WORK/restored.err" >&2; exit 2; }

probe --corrupt h2o > "$WORK/corrupt.log" 2>&1 || { echo "check_seal_cache: the bake could not be corrupted," >&2
	echo "                  so this gate has no positive control and its silence proves nothing." >&2
	tail -5 "$WORK/corrupt.log" >&2; exit 2; }
arm corrupted || { echo "check_seal_cache: the control arm did not report (exit $?)." >&2
	tail -5 "$WORK/corrupted.err" >&2; exit 2; }

python3 - "$WORK" <<'PY'
import json, math, os, sys

work = sys.argv[1]

def report(name):
	text = open(os.path.join(work, name + ".json")).read()
	start = text.index("{")
	return json.loads(text[start:text.rindex("}") + 1])

try:
	seeded, restored, corrupted = report("seeded"), report("restored"), report("corrupted")
except Exception as exc:
	print("check_seal_cache: an arm published no readable report (%s)." % exc, file=sys.stderr)
	sys.exit(2)

# What the seal says the world was handed, and what a stock reads on the step every baseline is taken on.
# THE BODY IS IN HERE because it is MEASURED, not stored: a load path that skips a measurement hands
# the next arm a planet weighed off a world it no longer holds.
ROWS = ["world_seed", "world_created", "creation_after_seal", "world_seal_step", "world_baseline_step",
	"energy_held_first", "mineral_first", "h2o_first", "o2_first", "element_C_total_first",
	"body_measured", "body_mass_kg", "body_radius_m", "body_inertia_kg_m2", "body_day_s"]

def close(a, b):
	if isinstance(a, float) and isinstance(b, float):
		if math.isnan(a) and math.isnan(b):
			return True
		return abs(a - b) <= 1e-9 * max(1.0, abs(a), abs(b))
	return a == b

fail = False
if restored.get("world_seal_origin") != "restored":
	print("FAIL  the loading arm sealed as '%s', so it seeded rather than reading the bake."
		% restored.get("world_seal_origin"), file=sys.stderr)
	fail = True
if seeded.get("world_seal_origin") != "seeded":
	print("FAIL  the seeding arm sealed as '%s'; the store was not empty and arm A proved nothing."
		% seeded.get("world_seal_origin"), file=sys.stderr)
	fail = True

for row in ROWS:
	if row not in seeded:
		print("FAIL  the seeding arm publishes no '%s', so this gate cannot compare it." % row, file=sys.stderr)
		fail = True
		continue
	if not close(seeded[row], restored.get(row)):
		print("FAIL  %s: the bake is not the world that was seeded." % row, file=sys.stderr)
		print("      seeded   %r" % (seeded[row],), file=sys.stderr)
		print("      restored %r" % (restored.get(row),), file=sys.stderr)
		fail = True

# THE POSITIVE CONTROL. A scaled h2o channel must reach h2o_first; if it does not, every SAME above is
# the comparison failing to look rather than the bake being faithful.
if close(seeded.get("h2o_first"), corrupted.get("h2o_first")):
	print("FAIL  a scaled h2o channel in the bake did not move h2o_first, so this gate cannot see a",
		file=sys.stderr)
	print("      corrupted bake and none of its agreements above mean anything.", file=sys.stderr)
	fail = True

if fail:
	sys.exit(1)
print("check_seal_cache: OK (the loaded world is the seeded world across %d rows, and a corrupted "
	"channel is seen)" % len(ROWS))
PY
