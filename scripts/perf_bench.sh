#!/usr/bin/env bash
# perf_bench.sh — sequential perf benchmark harness (dev tool).
#
# Runs a set of named configs ONE AT A TIME (never overlapping), so they never compete for the GPU the
# way two concurrent off-screen sims do — that competition is what makes ad-hoc runs give garbage,
# self-contradictory numbers. Each config runs off-screen (focus-safe, silent) through
# run_sim_offscreen.sh with its hard watchdog, then this prints a comparison table of averaged fps +
# frame-cost gauges. Crash-safe: a run that never emits SIM_REPORT is reported as CRASH, not skipped.
#
# Usage:
#   scripts/perf_bench.sh [suite]         suite = ablation | resolution | population | standard (default)
#   FRAMES=300 scripts/perf_bench.sh ablation
#   LA_RES=1280x720 scripts/perf_bench.sh ablation      # hold resolution fixed for an ablation
#
# Read the table as: cost of a system ~= (1000/fps_without) - (1000/fps_full) ms/frame.
set -u
cd "$(dirname "$0")/.." || exit 1
SCENE="addons/local_agents/scenes/simulation/voxel/VoxelWorld.tscn"
FRAMES="${FRAMES:-240}"
SUITE="${1:-standard}"
ALL_SYS="creatures,anim,plants,trees,fish,ecology,water,field"

# Nothing else may be running, or the numbers are contended — kill any stray off-screen sim first.
pkill -f "position 30000,30000" 2>/dev/null && sleep 1

printf '%-22s | %-8s | %-10s | %-9s | %-8s | %s\n' "config" "fps" "physics_ms" "field_ms" "draws" "actors"
printf -- '-%.0s' {1..80}; printf '\n'

run_one() {  # $1=label  $2=extra-env (space-sep KEY=VAL)  $3=extra-sim-args
  local label="$1"; local xenv="$2"; local xargs="$3"
  local out rep
  out=$(env $xenv LA_NO_STREAMER=1 LA_RUN_TIMEOUT=$(( FRAMES / 2 + 70 )) \
        scripts/run_sim_offscreen.sh --path . "$SCENE" -- --run-frames="$FRAMES" $xargs 2>&1)
  rep=$(echo "$out" | grep -oE "SIM_REPORT=.*" | tail -1)
  if [ -z "$rep" ]; then
    printf '%-22s | %s\n' "$label" "CRASH / no report"
    echo "$out" | grep -iE "SCRIPT ERROR|ERROR|abort|Segmentation|RUN_TIMEOUT|out of memory" | tail -2 | sed 's/^/    /'
    return
  fi
  echo "$rep" | LABEL="$label" python3 -c "
import sys,os,json
d=json.loads(sys.stdin.read().split('SIM_REPORT=',1)[1]); g=d.get('gauges',{})
def gv(k): return g.get(k,{}).get('cur',0)
print('%-22s | %-8s | %-10.1f | %-9.1f | %-8d | %s' % (
    os.environ['LABEL'], gv('fps'), gv('physics_ms'), gv('field_ms'),
    int(gv('draw_calls')), d.get('actors','-')))"
}

case "$SUITE" in
  ablation)
    run_one "full"             ""                          ""
    run_one "-creatures"       "LA_ABLATE=creatures,anim"  ""
    run_one "-plants+trees"    "LA_ABLATE=plants,trees"    ""
    run_one "-fish"            "LA_ABLATE=fish"            ""
    run_one "-ecology"         "LA_ABLATE=ecology"         ""
    run_one "-field"           "LA_ABLATE=field"           ""
    run_one "-water"           "LA_ABLATE=water"           ""
    run_one "-anim(models)"    "LA_ABLATE=anim"            ""
    run_one "ALL scripts off"  "LA_ABLATE=$ALL_SYS"        ""
    ;;
  resolution)
    for r in 640x400 1280x720 1920x1080 2560x1440; do run_one "res $r" "LA_RES=$r" ""; done
    ;;
  population)
    run_one "full"        "" ""
    run_one "smoke(potato)" "" "--smoke"
    ;;
  standard|*)
    run_one "full"            ""                          ""
    run_one "ALL scripts off" "LA_ABLATE=$ALL_SYS"        ""
    run_one "-plants+trees"   "LA_ABLATE=plants,trees"    ""
    run_one "-creatures"      "LA_ABLATE=creatures,anim"  ""
    run_one "-anim(models)"   "LA_ABLATE=anim"            ""
    ;;
esac
printf -- '-%.0s' {1..80}; printf '\n'
echo "done ($SUITE, ${FRAMES} frames each, sequential)"
