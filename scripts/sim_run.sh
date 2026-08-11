#!/usr/bin/env bash
# THE ONE WAY TO RUN THE PLANET AND READ ITS BOOKS.
#
# WHY THIS EXISTS. The verification run was being retyped by hand every time — a 200-character line carrying
# LA_RUN_TIMEOUT, LA_NO_STREAMER, the wrapper, --path, the scene, `--fixed-fps 60` BEFORE the `--`, then
# --sandbox --planet-only --no-fauna --run-frames --fast --seed. Every element of it is a thing that can be
# forgotten, and forgetting one silently changes what is being measured:
#   * omit the wrapper and a Godot window appears AND STEALS THE KEYBOARD mid-session;
#   * put --fixed-fps after the `--` and it is passed to the scene instead of the engine, which ignores it;
#   * forget --planet-only or --no-fauna and the arm is not the arm the debt table was measured on;
#   * skip the re-import and the compiled kernels are stale, so the numbers are fiction that looks fine.
# It also parses SIM_REPORT afterwards, which was being done with an inline python heredoc every single time.
#
# USAGE
#   scripts/sim_run.sh [--frames N] [--seed N] [--fast N] [--path DIR] [--fauna] [--full] [--keep]
#                      [--report k1,k2,...] [--raw] [-- <extra scene args>]
#
#   --frames N     run length (default 200; the conservation gate needs 600+ to audit at all)
#   --seed N       sim seed (default 4242 — the seed every recorded figure uses)
#   --fast N       time multiplier (default 8)
#   --path DIR     project dir (default .) — point it at a worktree
#   --fauna        keep animals (default --no-fauna: vegetation stays, animals do not)
#   --full         drop --planet-only (default is pure geophysics)
#   --report LIST  comma-separated SIM_REPORT keys to print (default: the conservation set)
#   --raw          print the whole SIM_REPORT as formatted JSON instead of a key list
#   --keep         keep the log file and print its path
#
# EXIT CODES: 0 clean · 3 stale shaders · 4 the run logged engine errors (numbers withheld) · 124 never
# reported · 125 hung after reporting · 126 CONSERVATION_VIOLATION.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

FRAMES=200
SEED=4242
FAST=8
PROJ="."
FAUNA=0
FULL=0
RAW=0
KEEP=0
REPORT_KEYS="conservation,conservation_failed,conservation_audited,energy_run_drift,energy_stock_first,energy_residual,energy_booked,o2_first,o2_total,mineral_first,mineral_total,h2o_first,h2o_total,element_C_total_first,element_C_total,temp_ground_p50,phenomena_kinds"
EXTRA=()

while [ $# -gt 0 ]; do
  case "$1" in
    --frames) FRAMES="$2"; shift 2 ;;
    --seed) SEED="$2"; shift 2 ;;
    --fast) FAST="$2"; shift 2 ;;
    --path) PROJ="$2"; shift 2 ;;
    --fauna) FAUNA=1; shift ;;
    --full) FULL=1; shift ;;
    --with-ui) WITH_UI=1; shift ;;
    --raw) RAW=1; shift ;;
    --keep) KEEP=1; shift ;;
    --report) REPORT_KEYS="$2"; shift 2 ;;
    --) shift; EXTRA=("$@"); break ;;
    -h|--help) sed -n '1,32p' "$0"; exit 0 ;;
    *) echo "sim_run: unknown argument '$1' (try --help)" >&2; exit 2 ;;
  esac
done

command -v godot >/dev/null 2>&1 || { echo "sim_run: godot is not on PATH. NO RUN HAPPENED." >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "sim_run: python3 is not on PATH (needed to read the report)." >&2; exit 2; }

# RE-IMPORT FIRST, ALWAYS. A .glsl edited since its last import leaves the compiled .res stale, and the run
# would load the OLD kernel and print a normal-looking report built on it. The wrapper refuses to launch a
# stale tree (exit 3), so this turns that refusal into a non-event instead of a thing to remember.
# Only import when a .glsl is newer than its compiled .res — a full import costs ~2.3s and most runs need none.
NEED_IMPORT=0
while IFS= read -r g; do
  base="$(basename "$g")"
  newest_res="$(ls -t "$PROJ/.godot/imported/${base}-"*.res 2>/dev/null | head -1)"
  if [ -z "$newest_res" ] || [ "$g" -nt "$newest_res" ]; then NEED_IMPORT=1; break; fi
done < <(find "$PROJ/addons" -name '*.glsl' 2>/dev/null)
if [ "$NEED_IMPORT" -eq 1 ]; then
  echo "sim_run: a kernel changed — importing." >&2
  godot --headless --path "$PROJ" --import >/dev/null 2>&1
fi

# --bare BY DEFAULT. A measurement run has no use for the HUD, the audio director, the ocean plane, the
# water particles, the vegetation renderer, the biome and sea-ice shaders, the drainage overlay or the
# thought panel — those are `add_child` calls guarded by `if not _input.bare()`, so bare does not hide them,
# it never builds them. Pass --with-ui to get them back for a look at the world.
ARGS=(--sandbox "--run-frames=${FRAMES}" "--fast=${FAST}" "--seed=${SEED}")
[ "${WITH_UI:-0}" -eq 0 ] && ARGS+=(--bare)
[ "$FULL" -eq 0 ] && ARGS+=(--planet-only)
[ "$FAUNA" -eq 0 ] && ARGS+=(--no-fauna)
[ "${#EXTRA[@]}" -gt 0 ] && ARGS+=("${EXTRA[@]}")

LOG="$(mktemp "${TMPDIR:-/tmp}/la_sim_run.XXXXXX")"
echo "sim_run: ${FRAMES} frames, seed ${SEED}, --fast=${FAST}${FULL:+}$([ "$FULL" -eq 0 ] && echo ' --planet-only')$([ "$FAUNA" -eq 0 ] && echo ' --no-fauna')" >&2

LA_RUN_TIMEOUT="${LA_RUN_TIMEOUT:-900}" \
  "$SCRIPT_DIR/run_sim_offscreen.sh" --path "$PROJ" \
  addons/local_agents/game/VoxelWorld.tscn --fixed-fps 60 \
  -- "${ARGS[@]}" > "$LOG" 2>&1
RC=$?

if grep -q '^CONSERVATION_VIOLATION=' "$LOG" 2>/dev/null; then
  echo "=== CONSERVATION_VIOLATION ===" >&2
  grep '^CONSERVATION_VIOLATION=' "$LOG" >&2
fi
if [ "$RC" -ne 0 ]; then
  # Truncate: one line of this log is a 40 KB SIM_REPORT, and dumping it raw buries the actual error.
  echo "sim_run: RUN FAILED, exit ${RC}. Last lines (truncated to 200 chars each):" >&2
  tail -15 "$LOG" | cut -c1-200 >&2
fi

# ERROR CENSUS FIRST, ALWAYS, AND IT IS FATAL. A run can emit a million SCRIPT ERROR lines and still print a
# perfectly normal SIM_REPORT; the first version of this script grepped only for get_spirv and printed the
# numbers, so a broken tree looked healthy for an entire session. If the engine complained, the numbers are
# not evidence of anything and this refuses to show them.
ERRS=$(grep -cE '^(SCRIPT )?ERROR:|errored bytecode|Parameter "shader" is null' "$LOG" 2>/dev/null || true)
if [ "${ERRS:-0}" -gt 0 ]; then
  echo "sim_run: ${ERRS} ENGINE ERROR LINE(S). THE RUN IS INVALID — numbers withheld." >&2
  grep -oE '^(SCRIPT )?ERROR: .{0,110}' "$LOG" | sort | uniq -c | sort -rn | head -8 >&2
  [ "$KEEP" -eq 1 ] && echo "sim_run: log kept at $LOG" >&2 || rm -f "$LOG"
  exit 4
fi

# A silently-dead GPU field prints a normal-looking report, so say so rather than letting a reader assume.
if grep -qiE "get_spirv|on a null value|errored bytecode|Parameter \"shader\" is null|SCRIPT ERROR" "$LOG" 2>/dev/null; then
  echo "sim_run: SHADER OR SCRIPT FAILURE in this run — every number below is fiction." >&2
  grep -iE "get_spirv|on a null value|errored bytecode|Parameter \"shader\" is null|SCRIPT ERROR" "$LOG" | head -5 >&2
fi

REPORT_KEYS="$REPORT_KEYS" RAW="$RAW" python3 - "$LOG" <<'PY'
import json, os, sys
log = sys.argv[1]
line = None
for ln in open(log, errors="replace"):
    if ln.startswith("SIM_REPORT="):
        line = ln
if line is None:
    print("sim_run: NO SIM_REPORT in this run.", file=sys.stderr)
    raise SystemExit(0)
d = json.loads(line.strip()[len("SIM_REPORT="):])
if os.environ.get("RAW") == "1":
    print(json.dumps(d, indent=2, sort_keys=True))
    raise SystemExit(0)
for k in os.environ["REPORT_KEYS"].split(","):
    k = k.strip()
    if not k:
        continue
    print(f"{k:26} = {d.get(k, '<ABSENT>')}")
# DRIFT, SPELLED OUT. A `_first`/`_total` pair is the whole point of the seal, and computing the ratio by
# hand every time is how a sign error survives (carbon read +1261% for a whole session against a true -10.7%).
print("--- drift vs sealed baseline ---")
for now_k, first_k in [("o2_total","o2_first"), ("mineral_total","mineral_first"),
                       ("h2o_total","h2o_first"), ("element_C_total","element_C_total_first")]:
    a, b = d.get(now_k), d.get(first_k)
    if isinstance(a,(int,float)) and isinstance(b,(int,float)) and b:
        print(f"{now_k:26} = {100.0*(a-b)/b:+8.3f}%")
PY

if [ "$KEEP" -eq 1 ]; then
  echo "sim_run: log kept at $LOG" >&2
else
  rm -f "$LOG"
fi
exit $RC
