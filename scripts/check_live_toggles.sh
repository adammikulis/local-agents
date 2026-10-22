#!/usr/bin/env bash
# ANY PROCESS THE WORLD CONTAINS SWITCHES OFF AND ON MID-RUN, THROUGH ONE REGISTRY. A body released from a
# co-rotating point keeps the ground's tangential velocity with gravity off, departs along the tangent, and
# accelerates again when the switch returns. A process the rung LACKS is refused; with test_masses off no
# probe falls. CONTROL: the same world with the switches on lands its probe.
# EXIT 0 the switches reach the world - 1 one does not - 2 the gate could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh"
. "$ROOT/scripts/lib_godot.sh"
. "$ROOT/scripts/lib_capture.sh"
. "$ROOT/scripts/lib_seal_key.sh"
la_examined "$(basename "$0")" || exit $?
require_tool python3

PROBE_REL="addons/local_agents/tests/gate_live_toggles.gd"
SCENE="addons/local_agents/game/VoxelWorld.tscn"
BOX="0,surface,0,3,24,3,5120,10"
FRAMES="${LA_LIVE_TOGGLE_FRAMES:-40}"
for f in "$PROBE_REL" "$SCENE"; do
	[ -f "$ROOT/$f" ] || { echo "check_live_toggles: no $f" >&2; exit 2; }
done

PROBE="$(mktemp "${TMPDIR:-/tmp}/la_toggle_probe.XXXXXX")"
OFF="$(mktemp "${TMPDIR:-/tmp}/la_toggle_off.XXXXXX")"
ON="$(mktemp "${TMPDIR:-/tmp}/la_toggle_on.XXXXXX")"
MASS="$(mktemp "${TMPDIR:-/tmp}/la_toggle_mass.XXXXXX")"
trap 'rm -f "$PROBE" "$OFF" "$ON" "$MASS"' EXIT INT TERM

# ARM 1 - the registry, the schedule, the panel and the free body, against the closed form.
export LA_ABLATE=gravity@2
la_godot --headless --path "$ROOT" -s "res://$PROBE_REL" > "$PROBE" 2>&1
probe_rc=$?
unset LA_ABLATE

# A switch is thrown on a step after the seed, so the three worlds below walk it once and read it back.
la_seal_key world=slice rung=1 "box=$BOX"

# ARM 2 - the rung-1 world with gravity switched off from its first step: nothing falls.
LA_SLICE_BOX="$BOX" LA_RUN_TIMEOUT="${LA_LIVE_TOGGLE_TIMEOUT:-110}" \
	"$ROOT/scripts/run_sim_offscreen.sh" --path "$ROOT" "$SCENE" -- --sandbox --rung=1 \
	--planet-only --ablate=gravity "--run-frames=$FRAMES" > "$OFF" 2>&1
off_rc=$?

# ARM 3 - THE CONTROL. The same world, same length, switch untouched: the probe reaches the ground.
LA_SLICE_BOX="$BOX" LA_RUN_TIMEOUT="${LA_LIVE_TOGGLE_TIMEOUT:-110}" \
	"$ROOT/scripts/run_sim_offscreen.sh" --path "$ROOT" "$SCENE" -- --sandbox --rung=1 \
	--planet-only "--run-frames=$FRAMES" > "$ON" 2>&1
on_rc=$?

# ARM 4 - the control's world with the test-mass module switched off by name.
LA_SLICE_BOX="$BOX" LA_RUN_TIMEOUT="${LA_LIVE_TOGGLE_TIMEOUT:-110}" \
	"$ROOT/scripts/run_sim_offscreen.sh" --path "$ROOT" "$SCENE" -- --sandbox --rung=1 \
	--planet-only --ablate=test_masses "--run-frames=$FRAMES" > "$MASS" 2>&1
mass_rc=$?

python3 - "$PROBE" "$probe_rc" "$OFF" "$ON" "$off_rc" "$on_rc" "$MASS" "$mass_rc" <<'PY'
import json, math, sys

probe_log, probe_rc, off_log, on_log, off_rc, on_rc = (
    sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4], int(sys.argv[5]), int(sys.argv[6]))
probe = open(probe_log, errors="replace").read()
off = open(off_log, errors="replace").read()
on = open(on_log, errors="replace").read()
mass, mass_rc = open(sys.argv[7], errors="replace").read(), int(sys.argv[8])
fails = []


def report(text, which):
    got = [l for l in text.splitlines() if l.startswith("SIM_REPORT=")]
    if not got:
        print("check_live_toggles: the %s arm published no SIM_REPORT, so nothing was measured."
              % which, file=sys.stderr)
        print("\n".join(text.splitlines()[-20:]), file=sys.stderr)
        sys.exit(2)
    return json.loads(got[-1][len("SIM_REPORT="):])


line = [l for l in probe.splitlines() if l.startswith("LIVE_TOGGLE_PROBE=")]
if not line:
    print("check_live_toggles: the probe published no LIVE_TOGGLE_PROBE line (exit %d)." % probe_rc,
          file=sys.stderr)
    print("\n".join(probe.splitlines()[-30:]), file=sys.stderr)
    sys.exit(2)
probe_fails = int(json.loads(line[-1][len("LIVE_TOGGLE_PROBE="):])["failures"])
if probe_fails:
    for l in probe.splitlines():
        if not l.startswith(("LIVE_TOGGLE_PROBE=", "SWITCH_PANEL=")):
            print("  " + l, file=sys.stderr)
    fails.append("the registry probe failed %d of its own claims" % probe_fails)

off_rep = report(off, "switched-off")
on_rep = report(on, "control")

# The switch was thrown, on the sim clock, and the world's own report says so.
toggles = [json.loads(l[len("PROCESS_TOGGLE="):]) for l in off.splitlines()
           if l.startswith("PROCESS_TOGGLE=")]
if not [t for t in toggles if t["name"] == "gravity" and t["on"] is False]:
    fails.append("the switched-off run printed no PROCESS_TOGGLE for gravity")
if off_rep.get("process_live", {}).get("gravity", None) is not False:
    fails.append("the switched-off run reports process_live gravity %r"
                 % off_rep.get("process_live", {}).get("gravity", None))
if on_rep.get("process_live", {}).get("gravity", None) is not True:
    fails.append("the control run reports process_live gravity %r"
                 % on_rep.get("process_live", {}).get("gravity", None))

# THE FIELD THE SWITCH LEFT BEHIND IS ZERO, not the last thing it solved: `ballistics_read_rel` compares
# what a free body falls under against the field's own mirror, so with both at zero it has no cell to
# compare and reads absent. A stale mirror beside a zero pull would read a whole unit of disagreement.
if "ballistics_read_rel" not in off_rep or "ballistics_read_rel" not in on_rep:
    print("check_live_toggles: neither run published ballistics_read_rel, so the field a body falls "
          "under went unread.", file=sys.stderr)
    sys.exit(2)
off_read = off_rep["ballistics_read_rel"]
on_read = on_rep["ballistics_read_rel"]
# A non-finite reading serialises as null: no cell had a pull to compare against, which is the claim.
if not (off_read is None or math.isnan(off_read)):
    fails.append("the switched-off run's integrator and field disagree by %r, so the field it left "
                 "behind is not zero" % off_read)
if on_read is None or math.isnan(on_read) or abs(on_read) > 1e-3:
    fails.append("the control run's integrator and field disagree by %r, so absence cannot be told "
                 "from agreement" % on_read)

# The probe was offered in both worlds: rung 1 contains gravity whether or not the switch is on.
for text, which in ((off, "switched-off"), (on, "control")):
    if "TEST_MASS_REFUSED=" in text:
        fails.append("the %s run refused the probe, so no body was ever released" % which)

# THE CLAIM: with gravity off nothing falls; with it on the same world lands its probe.
if "TEST_MASS_LANDED=" in off:
    fails.append("a probe reached the ground with gravity switched off")
if "TEST_MASS_LANDED=" not in on:
    print("check_live_toggles: the control run landed no probe in %d frames, so \"it did not land\""
          % len(on.splitlines()), file=sys.stderr)
    print("                   cannot be told from \"it never fell\". Raise LA_LIVE_TOGGLE_FRAMES.",
          file=sys.stderr)
    print("\n".join(on.splitlines()[-20:]), file=sys.stderr)
    sys.exit(2)

# THE MODULE: the name reaches the probe, and with it off nothing is released to land.
if "ABLATED={name:test_masses}" not in mass:
    fails.append("--ablate=test_masses switched off no module")
if "TEST_MASS_LANDED=" in mass:
    fails.append("a probe reached the ground with test_masses switched off")

for rc, which in ((off_rc, "switched-off"), (on_rc, "control"), (mass_rc, "test_masses-off")):
    if rc != 0:
        fails.append("the %s run exited %d" % (which, rc))

print('LIVE_TOGGLES={"probe_failures":%d,"toggles":%d,"landed_off":%s,"landed_on":%s,"landed_mass_off":%s}'
      % (probe_fails, len(toggles), str("TEST_MASS_LANDED=" in off).lower(),
         str("TEST_MASS_LANDED=" in on).lower(), str("TEST_MASS_LANDED=" in mass).lower()))
if fails:
    for f in fails:
        print("  " + f, file=sys.stderr)
    print("check_live_toggles: FAIL (%d)" % len(fails))
    sys.exit(1)
print("check_live_toggles: OK")
PY
