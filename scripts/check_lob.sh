#!/usr/bin/env bash
# AN ORB LOBBED HORIZONTALLY OVER THE BOX is in the air sqrt(2h/g) over the RADIAL drop h and the g it
# left in, and comes down v0*t along the throw; the rotating frame is separated by |a| = |2 w x v|, so no
# Coriolis term moves it further than w |v| t^2, along or across. ONE LOBBED IN FROM OUTSIDE crosses the
# box's face into the same field -- g r^2 is one number on both sides -- so nothing about its flight
# changes at the wall. CONTROL: the rung below solves no potential. EXIT 0 flew - 1 did not - 2 cannot.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh"
. "$ROOT/scripts/lib_godot.sh"
. "$ROOT/scripts/lib_capture.sh"
la_examined "$(basename "$0")" || exit $?
require_tool python3

# The experiment this gate declares. Over the box: fast enough that the throw dominates the fall, short
# enough that the arc stays inside the box's own footprint. Into the box: released clear of the outward
# face, slow enough across that it is still over the box when it lands.
LOB_SPEED="${LA_LOB_SPEED:-200}"
LOB_HEIGHT="${LA_LOB_HEIGHT:-2000}"
IN_SPEED="${LA_LOB_IN_SPEED:-50}"
IN_CLEARANCE="${LA_LOB_IN_CLEARANCE:-2000}"
# g's own change over the drop (2h/R) and the frame's centrifugal term are each well under a percent here.
BOUND="${LA_LOB_BOUND:-0.01}"

RUNG1="addons/local_agents/examples/SliceRung1Demo.tscn"
RUNG0="addons/local_agents/game/VoxelWorld.tscn"
BOX="0,surface,0,3,24,3,5120,10"
for f in "$RUNG1" "$RUNG0"; do
	[ -f "$ROOT/$f" ] || { echo "check_lob: no scene at $f" >&2; exit 2; }
done

SHOTS="${LA_LOB_SHOTS:-$(mktemp -d "${TMPDIR:-/tmp}/la_lob_shots.XXXXXX")}"
mkdir -p "$SHOTS" || exit 2
FLEW="$(mktemp "${TMPDIR:-/tmp}/la_lob_flew.XXXXXX")"
DRY="$(mktemp "${TMPDIR:-/tmp}/la_lob_dry.XXXXXX")"
trap 'rm -f "$FLEW" "$DRY"' EXIT INT TERM

# ARM 1 AND 2 - one launch of the rung-1 demo lobs both orbs, and photographs what it drew.
LA_RUN_TIMEOUT="${LA_LOB_TIMEOUT:-110}" "$ROOT/scripts/run_sim_offscreen.sh" --path "$ROOT" \
	"$RUNG1" -- --sandbox "--shoot=$SHOTS/lob.png" "--shots=6000:-60:0;6000:-60:180;200:-15:0" \
	--shoot-frames=150 --shoot-size=1280x800 \
	"--lob=$LOB_SPEED,$LOB_HEIGHT" "--lob-in=$IN_SPEED,$IN_CLEARANCE" > "$FLEW" 2>&1
flew_rc=$?

# THE CONTROL - the same box at the rung below, asked for the same two lobs.
LA_SLICE_BOX="$BOX" LA_RUN_TIMEOUT="${LA_LOB_TIMEOUT:-110}" \
	"$ROOT/scripts/run_sim_offscreen.sh" --path "$ROOT" "$RUNG0" -- --sandbox --ui --rung=0 \
	--planet-only --run-frames=30 "--lob=$LOB_SPEED,$LOB_HEIGHT" \
	"--lob-in=$IN_SPEED,$IN_CLEARANCE" > "$DRY" 2>&1
dry_rc=$?

python3 - "$FLEW" "$DRY" "$flew_rc" "$dry_rc" "$BOUND" "$LOB_SPEED" "$IN_SPEED" <<'PY'
import json, math, sys

flew_log, dry_log = sys.argv[1], sys.argv[2]
flew_rc, dry_rc = int(sys.argv[3]), int(sys.argv[4])
bound, lob_speed, in_speed = float(sys.argv[5]), float(sys.argv[6]), float(sys.argv[7])
flew = open(flew_log, errors="replace").read()
dry = open(dry_log, errors="replace").read()


def records(text, prefix):
    return [json.loads(l[len(prefix):]) for l in text.splitlines() if l.startswith(prefix)]


def cannot(msg, log):
    print("check_lob: " + msg, file=sys.stderr)
    print("\n".join(log.splitlines()[-20:]), file=sys.stderr)
    sys.exit(2)


landed = [r for r in records(flew, "TEST_MASS_LANDED=")
          if abs(float(r.get("throw_speed_m_s", 0.0)) - lob_speed) <= 1e-6 * lob_speed]
if not landed:
    cannot("the rung-1 run landed no orb thrown at %g m/s (exit %d), so the lob went unmeasured."
           % (lob_speed, flew_rc), flew)
released = [r for r in records(flew, "ORB_RELEASED=")
            if abs(float(r.get("throw_speed_m_s", 0.0)) - in_speed) <= 1e-6 * in_speed]
faces = records(flew, "ORB_FACE=")
if not released or not faces:
    cannot("the run placed no orb at %g m/s outside the box (exit %d), so the face went unread."
           % (in_speed, flew_rc), flew)
if int(released[-1].get("cell", 0)) >= 0:
    cannot("the orb meant to be lobbed IN was released inside the box (cell %d), so it crosses nothing."
           % int(released[-1].get("cell", 0)), flew)
crossed = [r for r in records(flew, "ORB_CROSSED=")
           if abs(float(r.get("throw_speed_m_s", 0.0)) - in_speed) <= 1e-6 * in_speed]

lob, face = landed[-1], faces[-1]
fails = []

# --- OVER THE BOX ---------------------------------------------------------------------------------
h, g = float(lob["height_m"]), float(lob["g_release"])
t, v = float(lob["time"]), float(lob["speed"])
along, across = float(lob["along_m"]), float(lob["cross_m"])
# A body whose moment of inertia nobody measured has no measured spin, so the frame it is in does not
# turn and there is no deflection to allow.
w = abs(float(lob["omega_rad_s"])) if "omega_rad_s" in lob else 0.0
if not (h > 0.0 and g > 0.0 and t > 0.0):
    cannot("the orb reports drop %r in gravity %r after %r s, so there is nothing to check against."
           % (h, g, t), flew)
t_free = math.sqrt(2.0 * h / g)
# The most a rotating frame can move it: |a| <= 2 w |v| for the whole flight, so |d| <= w |v| t^2.
coriolis_m = w * v * t * t
# The most the other bodies can: their pull less the pull at the centre is at most the larger of the
# release's and the landing's for the whole flight, so |d| <= |a| t^2 / 2.
if "tide_m_s2" not in lob:
    cannot("the orb row carries no tide, so the pull of the other bodies went unread.", flew)
tide_m = 0.5 * float(lob["tide_m_s2"]) * t * t
flat = lob_speed * t
# The floor under any displacement read off single-precision world positions: 32 ulps of the range.
noise_m = 32.0 * 2.0 ** -24 * max(flat, 1.0)
if abs(t - t_free) / t_free > bound:
    fails.append("it flew for %.4g s where sqrt(2h/g) is %.4g s" % (t, t_free))
if abs(along - flat) > coriolis_m + tide_m + noise_m + bound * flat:
    fails.append("it came down %.4g m along the throw where v0*t is %.4g m, past the %.3g m the frame's "
                 "rotation and the other bodies' tide could move it" % (along, flat, coriolis_m + tide_m))
if across > coriolis_m + tide_m + noise_m:
    fails.append("it drifted %.4g m across the throw where the frame's rotation and the other bodies' "
                 "tide allow %.3g m" % (across, coriolis_m + tide_m + noise_m))
if int(lob.get("cell", -1)) < 0:
    fails.append("it stopped outside the field box, so it landed on a declared radius and not on rock")

# --- INTO THE BOX ---------------------------------------------------------------------------------
edge = float(face["edge_m"])
g_in, g_out = float(face["g_in"]), float(face["g_out"])
r_in, r_out = float(face["r_in"]), float(face["r_out"])
if not (edge > 0.0 and r_in > 0.0 and g_in > 0.0):
    cannot("the crossing reports cell edge %r, radius %r and inside gravity %r, so the face carries no "
           "field to compare." % (edge, r_in, g_in), flew)
# A mirror sampled at cell centres cannot resolve g better than one cell: g varies by 2 dr / r over dr.
face_bound = 2.0 * edge / r_in
mu_in, mu_out = g_in * r_in * r_in, g_out * r_out * r_out
if int(face.get("cell_out", 0)) >= 0 or int(face.get("cell_in", -1)) < 0:
    fails.append("the two samples do not straddle the face: cells %d outside and %d inside"
                 % (int(face.get("cell_out", 0)), int(face.get("cell_in", -1))))
if abs(mu_out - mu_in) / mu_in > face_bound:
    fails.append("g r^2 reads %.6g m^3/s^2 outside the face and %.6g inside, so the pull the orb flew "
                 "through changes at the wall" % (mu_out, mu_in))
for side in ("in", "out"):
    radial = float(face["radial_" + side])
    if radial < 1.0 - face_bound:
        fails.append("gravity %.6g of the way along the local down %s the face" % (radial, side))
# The flight across the face: it must actually get in, and arrive at the speed the pull it fell through
# gives it, v^2 - v0^2 = 2 gbar dr over the radial distance it came down.
speed_rel, drop_bound = float("nan"), float("nan")
if not crossed:
    fails.append("the orb released %.4g m above the box's face in a gravity of %.4g m/s^2 never entered "
                 "it, so the pull outside the wall is not the pull that box stands in"
                 % (float(released[-1]["r_release"]) - (r_out - 0.5 * edge),
                    float(released[-1]["g_release"])))
else:
    cross = crossed[-1]
    dr = float(cross["r_release"]) - float(cross["r_entry"])
    gbar = 0.5 * (float(cross["g_release"]) + float(cross["g_entry"]))
    v0, v1 = float(cross["v_release"]), float(cross["v_entry"])
    gained, expect = v1 * v1 - v0 * v0, 2.0 * gbar * dr
    if not (dr > 0.0 and expect > 0.0):
        cannot("the orb came down %r m into a mean gravity of %r, so its entry speed answers nothing."
               % (dr, gbar), flew)
    # g itself changes by 2 dr / r over the drop: the floor on a constant-gravity comparison.
    drop_bound = 2.0 * dr / float(cross["r_release"])
    speed_rel = abs(gained - expect) / expect
    if speed_rel > drop_bound:
        fails.append("it entered the box at %.6g m/s where the pull it fell through gives %.6g m/s"
                     % (v1, math.sqrt(max(v0 * v0 + expect, 0.0))))

# --- THE RUN ITSELF -------------------------------------------------------------------------------
if "TEST_MASS_REFUSED=" in flew:
    fails.append("the rung-1 run refused the probes it then lobbed")
if flew_rc != 0:
    fails.append("the rung-1 run exited %d" % flew_rc)

# --- THE CONTROL: rung 0 solves no potential, so it offers no probe and lobs nothing ----------------
if "TEST_MASS_REFUSED=" not in dry:
    fails.append("the rung-0 world did not refuse the probe, so the refusal cannot fail either")
if "TEST_MASS_LANDED=" in dry:
    fails.append("the rung-0 world landed an orb it never released")
if "ORB_RELEASED=" in dry:
    fails.append("the rung-0 world released an orb into a field it does not solve")
if dry_rc != 0:
    fails.append("the rung-0 run exited %d" % dry_rc)

print('LOB={"g_release":%.4f,"drop_m":%.1f,"flight_rel":%.2e,"along_rel":%.2e,"across_m":%.3g,'
      '"coriolis_m":%.3g,"tide_m":%.3g,"noise_m":%.3g,"spin":"%s","cell":%d}'
      % (g, h, abs(t - t_free) / t_free, abs(along - flat) / flat, across, coriolis_m, tide_m, noise_m,
         "measured" if "omega_rad_s" in lob else "unmeasured", int(lob.get("cell", -1))))
print('LOB_FACE={"edge_m":%.1f,"g_out":%.6g,"g_in":%.6g,"mu_rel":%.2e,"face_bound":%.2e,'
      '"speed_rel":%.2e,"drop_bound":%.2e,"cell_out":%d,"cell_in":%d,"crossed":%s}'
      % (edge, g_out, g_in, abs(mu_out - mu_in) / mu_in, face_bound, speed_rel, drop_bound,
         int(face.get("cell_out", 0)), int(face.get("cell_in", -1)), str(bool(crossed)).lower()))
if fails:
    for f in fails:
        print("  " + f, file=sys.stderr)
    print("check_lob: FAIL (%d)" % len(fails))
    sys.exit(1)
print("check_lob: OK")
PY
rc=$?
grep '^SHOT_SAVED=' "$FLEW" >&2
exit $rc
