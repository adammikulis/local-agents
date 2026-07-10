#!/usr/bin/env bash
# fixture_check.sh — deterministic save round-trip gate. LOADS the committed `stable_world` fixture (a real
# save produced by the game's own save system) via `--smoke --load-fixture=<dir>`, runs a short delta, and
# asserts the restored state (SAVE_STATE_LOADED) is within tolerance of the reference in expected.json. This
# is faster + more deterministic than booting and growing a world every verification run.
#
# The fixture is authored AND loaded under --smoke so the Potato grid's cell_count matches on restore
# (MaterialFieldSnapshot3D guards on cell_count). The gate keys off the emitted report lines, not godot's
# process exit code (macOS Metal teardown can abort AFTER the report — not a sim failure).
#
# Usage:  scripts/fixture_check.sh [--frames=N]
#   --frames=N   frames to run after the restore (the "short delta"), default 120.
#
# Prints:  FIXTURE_CHECK: PASS   |   FIXTURE_CHECK: FAIL (<why>).  Exit 0 pass / non-zero fail.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCENE="addons/local_agents/scenes/simulation/voxel/VoxelWorld.tscn"
FIXTURE_DIR="addons/local_agents/scenes/simulation/voxel/test/fixtures/stable_world"
FRAMES=120

for arg in "$@"; do
  case "$arg" in
    --frames=*) FRAMES="${arg#--frames=}" ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "fixture_check: unknown arg '$arg'" >&2; exit 2 ;;
  esac
done

cd "$REPO_ROOT"
if [[ ! -f "$FIXTURE_DIR/world.sav" ]]; then
  echo "FIXTURE_CHECK: FAIL (fixture blob missing at $FIXTURE_DIR/world.sav)"
  exit 1
fi
LOG_DIR="${LOG_DIR:-${TMPDIR:-/tmp}}"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/fixture_check_$(date +%s).log"

LA_NO_STREAMER=1 LA_NO_EVENT_TRACKER=1 \
  "$SCRIPT_DIR/run_sim_offscreen.sh" --path . "$SCENE" -- --smoke --load-fixture="$FIXTURE_DIR" --run-frames="$FRAMES" \
  > "$LOG_FILE" 2>&1

if grep -qiE 'SCRIPT ERROR|Parse Error|Failed loading resource|dependency error' "$LOG_FILE"; then
  echo "FIXTURE_CHECK: FAIL (script/parse error in log — see $LOG_FILE)"
  exit 1
fi

FIXTURE_DIR="$FIXTURE_DIR" python3 - "$LOG_FILE" <<'PY'
import json, os, re, sys

log = sys.argv[1]
def fail(msg):
    print("FIXTURE_CHECK: FAIL (%s)" % msg)
    sys.exit(1)

text = open(log, "r", errors="replace").read()

# The restore must have actually happened, and a short delta must have run (final SIM_REPORT emitted).
if "SAVE_LOAD_DONE=" not in text:
    fail("fixture never restored (no SAVE_LOAD_DONE — see %s)" % log)
if "SIM_REPORT=" not in text:
    fail("no SIM_REPORT after the delta (the sim did not run the short delta — see %s)" % log)

m = re.search(r"SAVE_STATE_LOADED=\{([^}]*)\}", text)
if not m:
    fail("no SAVE_STATE_LOADED line (restore did not report — see %s)" % log)

# Parse the `key:value, key:value` payload into a dict of floats.
loaded = {}
for pair in m.group(1).split(","):
    if ":" not in pair:
        continue
    k, v = pair.split(":", 1)
    try:
        loaded[k.strip()] = float(v.strip())
    except ValueError:
        pass

exp = json.load(open(os.path.join(os.environ["FIXTURE_DIR"], "expected.json")))
tol = exp["tolerance"]

def check_abs(name, key, tol_abs):
    got = loaded.get(key)
    if got is None:
        fail("restored state missing '%s'" % key)
    if abs(got - float(exp[name])) > tol_abs:
        fail("%s off: got %.2f, expected %.2f +/- %d" % (key, got, float(exp[name]), tol_abs))

def check_pct(name, key, tol_pct):
    got = loaded.get(key)
    if got is None:
        fail("restored state missing '%s'" % key)
    ref = float(exp[name])
    if abs(got - ref) > abs(ref) * tol_pct + 1e-6:
        fail("%s off: got %.2f, expected %.2f +/- %.0f%%" % (key, got, ref, tol_pct * 100))

check_abs("creatures", "creatures", tol["creatures_abs"])
check_abs("fish", "fish", tol["fish_abs"])
check_pct("h2o", "h2o", tol["h2o_pct"])
check_pct("mineral", "mineral", tol["mineral_pct"])
check_pct("biomass", "biomass", tol["biomass_pct"])

print("FIXTURE_CHECK: PASS (round-trip: creatures=%d, fish=%d, h2o=%.1f, mineral=%.0f, biomass=%.1f matched expected within tolerance; short delta ran)" % (
    int(loaded["creatures"]), int(loaded["fish"]), loaded["h2o"], loaded["mineral"], loaded["biomass"]))
sys.exit(0)
PY
exit $?
