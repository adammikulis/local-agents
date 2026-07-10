#!/usr/bin/env bash
# smoke_check.sh — the STANDARD fast health gate for the voxel sim. Boots the minimal (--smoke: Potato
# grid + Low actor budget + effects/streamer/disasters off) config through the offscreen wrapper, runs a
# short window, and asserts the key SIM_REPORT invariants. This is what agents/CI reuse instead of
# hand-rolling "does it still parse + run + not blow up" checks.
#
# Usage:  scripts/smoke_check.sh [--frames=N] [--scene=PATH] [--fps-floor=F]
#   --frames=N     sim frames to run before the SIM_REPORT snapshot (default 150)
#   --scene=PATH   scene to boot (default the voxel world); override to prove the gate FAILS on a bad scene
#   --fps-floor=F  minimum acceptable fps (default 1.0 — a HANG/stall guard, not a playability bar: --smoke
#                  runs the field as fast as it can, so fps is a stress number, not the shipped frame-rate)
#
# Prints one line:  SMOKE_CHECK: PASS   |   SMOKE_CHECK: FAIL (<which assertion>)
# Exit 0 on pass, non-zero on fail. The gate keys off SIM_REPORT CONTENT, not godot's process exit code:
# on macOS the Metal/MoltenVK teardown can abort (exit 134) AFTER the report is printed — that is not a
# sim failure, so we assert on the emitted report instead.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCENE="addons/local_agents/scenes/simulation/voxel/VoxelWorld.tscn"
FRAMES=150
FPS_FLOOR=1.0

for arg in "$@"; do
  case "$arg" in
    --frames=*) FRAMES="${arg#--frames=}" ;;
    --scene=*) SCENE="${arg#--scene=}" ;;
    --fps-floor=*) FPS_FLOOR="${arg#--fps-floor=}" ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "smoke_check: unknown arg '$arg'" >&2; exit 2 ;;
  esac
done

cd "$REPO_ROOT"
LOG_DIR="${LOG_DIR:-${TMPDIR:-/tmp}}"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/smoke_check_$(date +%s).log"

# Boot the minimal config. Streamer + event tracker are also killed by env for a fully quiet, fast boot.
LA_NO_STREAMER=1 LA_NO_EVENT_TRACKER=1 \
  "$SCRIPT_DIR/run_sim_offscreen.sh" --path . "$SCENE" -- --smoke --run-frames="$FRAMES" \
  > "$LOG_FILE" 2>&1
# (godot's exit code is intentionally ignored — see header.)

# Hard script-health signals: a genuine parse/script/dependency error is always a FAIL, regardless of report.
if grep -qiE 'SCRIPT ERROR|Parse Error|Failed loading resource|dependency error' "$LOG_FILE"; then
  echo "SMOKE_CHECK: FAIL (script/parse error in log — see $LOG_FILE)"
  exit 1
fi

SIM_REPORT_LINE="$(grep -o 'SIM_REPORT=.*' "$LOG_FILE" | tail -n 1 | sed 's/^SIM_REPORT=//')"
if [[ -z "$SIM_REPORT_LINE" ]]; then
  echo "SMOKE_CHECK: FAIL (no SIM_REPORT emitted — the sim never reached frame $FRAMES; see $LOG_FILE)"
  exit 1
fi

# Assert the invariants in python3 (robust JSON + finite checks). Exit code / message come from here.
SIM_REPORT="$SIM_REPORT_LINE" FPS_FLOOR="$FPS_FLOOR" python3 - "$LOG_FILE" <<'PY'
import json, math, os, sys

log = sys.argv[1]
fps_floor = float(os.environ["FPS_FLOOR"])

def fail(msg):
    print("SMOKE_CHECK: FAIL (%s)" % msg)
    sys.exit(1)

try:
    r = json.loads(os.environ["SIM_REPORT"])
except Exception as e:
    fail("SIM_REPORT is not valid JSON (%s) — see %s" % (e, log))

gauges = r.get("gauges", {})
def gauge(name, field="max"):
    g = gauges.get(name)
    if not isinstance(g, dict):
        return None
    return g.get(field)

# 1. Population alive.
creatures = int(r.get("creatures", 0))
if creatures <= 0:
    fail("population is zero (creatures=%d)" % creatures)

# 2. Herds forming / life alive: followers seen at some point, OR creatures are alive.
followers = gauge("followers", "max") or 0.0
if not (followers > 0 or creatures > 0):
    fail("no herds and no living creatures (followers_max=%s, creatures=%d)" % (followers, creatures))

# 3. Field conservation channels finite AND non-zero.
for key in ("h2o_total", "mineral_total", "biomass_total"):
    if key not in r:
        fail("field channel '%s' missing from report" % key)
    v = r[key]
    if not isinstance(v, (int, float)) or not math.isfinite(float(v)):
        fail("field channel '%s' is not finite (%r) — NaN/inf" % (key, v))
    if abs(float(v)) <= 0.0:
        fail("field channel '%s' is zero (%r)" % (key, v))

# 4. Not hung: fps above the floor.
fps = gauge("fps", "max")
if fps is None:
    fail("fps gauge missing from report")
if float(fps) < fps_floor:
    fail("fps below floor (%.2f < %.2f) — sim stalled" % (float(fps), fps_floor))

print("SMOKE_CHECK: PASS (creatures=%d, followers_max=%d, h2o=%.1f, mineral=%.0f, biomass=%.1f, fps=%.1f)" % (
    creatures, int(followers), float(r["h2o_total"]), float(r["mineral_total"]),
    float(r["biomass_total"]), float(fps)))
sys.exit(0)
PY
exit $?
