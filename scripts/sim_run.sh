#!/usr/bin/env bash
# THE ONE WAY TO RUN THE PLANET AND READ ITS BOOKS, so that no element of the invocation can be
# forgotten. Omit the wrapper and a Godot window steals the keyboard; put --fixed-fps after the `--` and
# the engine never sees it; forget --planet-only or --no-fauna and the arm is not the arm it is compared
# against; skip the re-import and the compiled kernels are stale. It parses SIM_REPORT afterwards too.

# USAGE
#   scripts/sim_run.sh [--frames N] [--seed N] [--rung N] [--path DIR] [--fauna] [--full] [--keep]
#                      [--from-seal]
#                      [--slice] [--slice-box SPEC] [--slice-state FILE] [--slice-capture FILE]
#                      [--report k1,k2,...] [--raw] [-- <extra scene args>]

#   --frames N     run length in SIMULATED STEPS (default 200; the conservation gate needs 600+)
#   --rung N | --seed N   the processes the world contains (LAProcessSet, default docs/PLAYABLE_RUNG) / sim seed
#   --path DIR     project dir (default .) — point it at a worktree
#   --fauna | --full  keep animals (needs --full) / drop --planet-only (default is pure geophysics)
#   --slice [--slice-box "ox,oy,oz,nx,ny,nz,cell_m"]  run a SLICE (default: surface at +Y, 24x32x24 of 4 km)
#   --slice-state F | --slice-capture F  consume a face-state capture in a slice / record one in a GLOBAL run
#   --report LIST  comma-separated SIM_REPORT keys to print (default: the conservation set)
#   --raw | --keep  print the whole SIM_REPORT as formatted JSON / keep the log file and print its path
#   --from-seal    seed the world from the bake this arm's key names, writing one on a miss

# EXIT 0 clean · 3 stale shaders · 4 the run logged engine errors, numbers withheld · 5 a UI node was
# built without --ui · 124 never reported · 125 hung after reporting · 126 CONSERVATION_VIOLATION.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

FRAMES=200
SEED=4242
RUNG=""
PROJ="."
FAUNA=0
FULL=0
RAW=0
KEEP=0
SLICE=0
SLICE_BOX=""
SLICE_STATE=""
SLICE_CAPTURE=""
FROM_SEAL=0
REPORT_KEYS="conservation,conservation_failed,conservation_audited,energy_run_drift,energy_held_first,energy_residual,energy_booked,o2_first,o2_total,mineral_first,mineral_total,h2o_first,h2o_total,element_C_total_first,element_C_total,temp_ground_mean,phenomena_kinds,field_ms,transport_levels"
EXTRA=()

while [ $# -gt 0 ]; do
  case "$1" in
    --frames) FRAMES="$2"; shift 2 ;;
    --seed) SEED="$2"; shift 2 ;;
    --rung) RUNG="$2"; shift 2 ;;
    --rung=*) RUNG="${1#--rung=}"; shift ;;
    --path) PROJ="$2"; shift 2 ;;
    --fauna) FAUNA=1; shift ;;
    --full) FULL=1; shift ;;
    --with-ui) WITH_UI=1; shift ;;
    --slice) SLICE=1; shift ;;
    --slice-box) SLICE=1; SLICE_BOX="$2"; shift 2 ;;
    --slice-state) SLICE_STATE="$2"; shift 2 ;;
    --slice-capture) SLICE_CAPTURE="$2"; shift 2 ;;
    --from-seal) FROM_SEAL=1; shift ;;
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
# would load the OLD kernel and print a normal-looking report built on it. godot_import.sh answers whether
# anything actually changed and costs a hash when nothing has.
"$SCRIPT_DIR/godot_import.sh" "$PROJ"

# NO PRESENTATION BY DEFAULT. A measurement run has no use for the HUD, the audio director, the ocean
# plane, the water particles, the vegetation renderer, the biome and sea-ice shaders, the drainage overlay
# or the thought panel. The UiLayer scene is instantiated only under --ui, so the default does not hide
# them, it never builds them. Pass --with-ui to get them back for a look at the world.
# --planet-only builds no life, so --fauna beside it is a no-op the run would report as success.
if [ "$FAUNA" -eq 1 ] && [ "$FULL" -eq 0 ]; then
	echo "sim_run: --fauna needs --full. Without it the arm is --planet-only, which builds no life," >&2
	echo "         so --fauna would change nothing and the run would not be the arm you asked for." >&2
	exit 2
fi
# --- SLICE / CAPTURE ENV. The default box stands on the surface at +Y. `surface` is resolved by the world
# against the body's own radius: nothing out here has to know how big the planet is.
if [ "$SLICE" -eq 1 ] || [ -n "$SLICE_CAPTURE" ]; then
  [ -n "$SLICE_BOX" ] || SLICE_BOX="0,surface,0,24,32,24,4000"
fi
if [ "$SLICE" -eq 1 ]; then
  export LA_SLICE_BOX="$SLICE_BOX"
  [ -n "$SLICE_STATE" ] && export LA_SLICE_STATE="$SLICE_STATE"
elif [ -n "$SLICE_STATE" ]; then
  echo "sim_run: --slice-state without --slice names a boundary no run consumes." >&2
  exit 2
fi
if [ -n "$SLICE_CAPTURE" ]; then
  if [ "$SLICE" -eq 1 ]; then
    echo "sim_run: --slice-capture is a GLOBAL run's flag; a slice cannot record its own exterior." >&2
    exit 2
  fi
  export LA_SLICE_CAPTURE="$SLICE_CAPTURE"
  export LA_SLICE_CAPTURE_BOX="$SLICE_BOX"
fi

ARGS=(--sandbox "--run-frames=${FRAMES}" "--seed=${SEED}")
[ -n "$RUNG" ] && ARGS+=("--rung=${RUNG}")
[ "${WITH_UI:-0}" -eq 1 ] && ARGS+=(--ui)
[ "$FULL" -eq 0 ] && ARGS+=(--planet-only)
[ "$FAUNA" -eq 0 ] && ARGS+=(--no-fauna)
[ "${#EXTRA[@]}" -gt 0 ] && ARGS+=("${EXTRA[@]}")

# THE SEEDING WALKS ARE A FUNCTION OF THIS ARM, NOT OF ITS LENGTH: the frame count is left out of the key
# on purpose, so every arm over one world shares one bake.
if [ "$FROM_SEAL" -eq 1 ]; then
  SEAL_KEY="$("$SCRIPT_DIR/cache_key.sh" capture --path "$PROJ" "seed=$SEED" "rung=${RUNG:-default}" \
    "full=$FULL" "fauna=$FAUNA" "slice=$SLICE" \
    "box=$(if [ "$SLICE" -eq 1 ]; then printf '%s' "$SLICE_BOX"; fi)" 2>/dev/null || echo "")"
  if [ -n "$SEAL_KEY" ]; then
    export LA_SEAL_KEY="$SEAL_KEY"
  else
    echo "sim_run: --from-seal, but no content key describes this tree, so this arm seeds." >&2
  fi
fi

LOG="$(mktemp "${TMPDIR:-/tmp}/la_sim_run.XXXXXX")"
echo "sim_run: ${FRAMES} steps, seed ${SEED}${FULL:+}$([ "$FULL" -eq 0 ] && echo ' --planet-only')$([ "$FAUNA" -eq 0 ] && echo ' --no-fauna')" >&2

LA_RUN_TIMEOUT="${LA_RUN_TIMEOUT:-120}" \
  "$SCRIPT_DIR/run_sim_offscreen.sh" --path "$PROJ" \
  addons/local_agents/game/VoxelWorld.tscn --fixed-fps 60 \
  -- "${ARGS[@]}" > "$LOG" 2>&1
RC=$?

if grep -q '^CONSERVATION_VIOLATION=' "$LOG" 2>/dev/null; then
  echo "=== CONSERVATION_VIOLATION ===" >&2
  grep '^CONSERVATION_VIOLATION=' "$LOG" >&2
fi

# NO UI IN A SIMULATION RUN. This arm never passes --ui, so any Control / CanvasLayer in the tree is a
# presentation node that leaked into the physics-only path. That has happened twice: the sim clock lived in
# a CanvasLayer owning the global clock, and the CLI parser built the Esc menu + the view-controls bar.
# Behavioural, so a UI node added anywhere in future trips it without anyone remembering a rule.
# THE NEIGHBOUR TABLE IS THE CONTRACT EVERY FLOW KERNEL RIDES ON. If slot-opposite reciprocity fails, mass
# moves into slots that never answer back and no number in the run is a measurement.
if grep -q '^GRID_INVALID=' "$LOG" 2>/dev/null; then
  echo "sim_run: GRID_INVALID — the sphere neighbour table is not slot-opposite reciprocal." >&2
  grep '^GRID_INVALID=' "$LOG" | head -1 >&2
  [ "$KEEP" -eq 1 ] && echo "sim_run: log kept at $LOG" >&2 || rm -f "$LOG"
  exit 6
fi

WANT_UI=0
for a in "${ARGS[@]}"; do [ "$a" = "--ui" ] && WANT_UI=1; done
UI_N=$(grep -oE '"ui_nodes":[0-9]+' "$LOG" 2>/dev/null | tail -1 | cut -d: -f2)
if [ "$WANT_UI" -eq 0 ] && [ -n "${UI_N:-}" ] && [ "$UI_N" -gt 0 ]; then
  echo "sim_run: ${UI_N} UI NODE(S) BUILT IN A RUN WITH NO --ui. The presentation layer leaked into the" >&2
  echo "         simulation path — find what built a Control/CanvasLayer and move it into Presentation.gd." >&2
  [ "$KEEP" -eq 1 ] && echo "sim_run: log kept at $LOG" >&2 || rm -f "$LOG"
  exit 5
fi
# 126 and 123 are PHYSICS VERDICTS from run_sim_offscreen.sh, not a failed run: the sim completed and the
# books say a substance was created or could not be measured. Reporting them as "RUN FAILED" is how a real
# verdict gets read as a broken harness and then muted.
if [ "$RC" -eq 126 ]; then
  echo "sim_run: the run completed and CONSERVATION_VIOLATION fired." >&2
elif [ "$RC" -eq 123 ]; then
  echo "sim_run: the run completed and a substance was UNMEASURED." >&2
elif [ "$RC" -ne 0 ]; then
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

# The probe prints through godot's stdout, which the exit path can truncate; the --log-file tap flushes
# live, so the tap is the record and this forwards it, deduplicated against the lines that got through.
grep '^PASS_PROBE=' "$LOG" 2>/dev/null | awk '!seen[$0]++' || true

REPORT_KEYS="$REPORT_KEYS" RAW="$RAW" python3 "$SCRIPT_DIR/lib_report.py" "$LOG"

if [ "$KEEP" -eq 1 ]; then
  echo "sim_run: log kept at $LOG" >&2
else
  rm -f "$LOG"
fi
exit $RC
