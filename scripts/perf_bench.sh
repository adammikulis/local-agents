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
#   scripts/perf_bench.sh resolution                    # sweep the off-screen render target size
#
# Read the table as: cost of a system ~= (1000/fps_without) - (1000/fps_full) ms/frame.
#
# Drives the in-engine --perf-frames path (VoxelWorld._process), which averages fps + a CPU/GPU render split
# over a trailing window using Godot's own instrumentation: Performance monitors for the CPU sim cost and
# RenderingServer.viewport_get_measured_render_time_{gpu,cpu} for the render split. So the table shows whether
# a config is GPU-bound (gpu_ms) or CPU-bound (proc_ms) — raw fps alone cannot, and the old single-frame
# report gauges timed the heavy report frame and self-contradicted.
set -u
cd "$(dirname "$0")/.." || exit 1
SCENE="addons/local_agents/game/VoxelWorld.tscn"
FRAMES="${FRAMES:-240}"
SUITE="${1:-standard}"
ALL_SYS="creatures,anim,plants,trees,fish,ecology,water,field"

# NOTE: process_ms (Performance.TIME_PROCESS) is deliberately NOT shown — it reads ~constant regardless of
# what is ablated (it does not track the actual frame cost on this build), so it is misleading. frame_ms is
# the ground truth (summed _process delta). cpuR_ms is CPU draw submission (viewport render-time-cpu).
printf '%-22s | %-7s | %-8s | %-8s | %-8s | %s\n' "config" "fps" "frame_ms" "cpuR_ms" "draws" "actors"
printf -- '-%.0s' {1..80}; printf '\n'

run_one() {  # $1=label  $2=extra-env (space-sep KEY=VAL)  $3=extra-sim-args
  local label="$1"; local xenv="$2"; local xargs="$3"
  local out rep
  out=$(env $xenv LA_RUN_TIMEOUT=$(( FRAMES / 2 + 200 )) \
        scripts/run_sim_offscreen.sh --path . "$SCENE" \
        -- --sandbox --ui --perf-frames="$FRAMES" $xargs 2>&1)
  rep=$(echo "$out" | grep -oE "PERF=.*" | tail -1)
  if [ -z "$rep" ]; then
    printf '%-22s | %s\n' "$label" "CRASH / no report"
    echo "$out" | grep -iE "SCRIPT ERROR|ERROR|abort|Segmentation|RUN_TIMEOUT|out of memory" | tail -2 | sed 's/^/    /'
    return
  fi
  echo "$rep" | LABEL="$label" python3 -c "
import sys,os,json
d=json.loads(sys.stdin.read().split('PERF=',1)[1])
fps=d['fps']
print('%-22s | %-7.1f | %-8.2f | %-8.2f | %-8d | %s' % (
    os.environ['LABEL'], fps, d.get('frame_ms',1000.0/max(fps,0.001)), d['cpu_render_ms'], d['draw_calls'],
    d.get('actors',0)))"
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
    for r in 640x400 1280x720 1920x1080 2560x1440; do run_one "res $r" "" "--shoot-size=$r"; done
    ;;
  population)
    run_one "full"        "" ""
    run_one "smoke(potato)" "" "--smoke"
    ;;
  list)
    # Custom ablation list: every arg after `list` is one LA_ABLATE value ("" = baseline). Lets a focused
    # sweep run exactly the configs you name instead of a fixed suite.
    shift
    for ab in "$@"; do
      lbl="${ab:-<baseline>}"
      run_one "$lbl" "LA_ABLATE=$ab" ""
    done
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
