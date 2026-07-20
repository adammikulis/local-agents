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
#
# Drives the in-engine --perf-frames path (VoxelWorld._process), which averages fps + a CPU/GPU render split
# over a trailing window using Godot's own instrumentation: Performance monitors for the CPU sim cost and
# RenderingServer.viewport_get_measured_render_time_{gpu,cpu} for the render split. So the table shows whether
# a config is GPU-bound (gpu_ms) or CPU-bound (proc_ms) — raw fps alone cannot, and the old single-frame
# report gauges timed the heavy report frame and self-contradicted.
set -u
cd "$(dirname "$0")/.." || exit 1
SCENE="addons/local_agents/scenes/simulation/voxel/VoxelWorld.tscn"
FRAMES="${FRAMES:-240}"
SUITE="${1:-standard}"
ALL_SYS="creatures,anim,plants,trees,fish,ecology,water,field"

# Nothing else may be running, or the numbers are contended — kill any stray off-screen sim first.
pkill -f "run_sim_offscreen" 2>/dev/null; pkill -f "rendering-driver metal" 2>/dev/null && sleep 1

printf '%-22s | %-7s | %-8s | %-8s | %-9s | %-8s | %s\n' "config" "fps" "frame_ms" "cpuR_ms" "process_ms" "draws" "actors"
printf -- '-%.0s' {1..92}; printf '\n'

run_one() {  # $1=label  $2=extra-env (space-sep KEY=VAL)  $3=extra-sim-args
  local label="$1"; local xenv="$2"; local xargs="$3"
  local out rep
  out=$(env $xenv LA_NO_STREAMER=1 LA_RUN_TIMEOUT=$(( FRAMES / 2 + 90 )) \
        scripts/run_sim_offscreen.sh --path . "$SCENE" -- --perf-frames="$FRAMES" $xargs 2>&1)
  rep=$(echo "$out" | grep -oE "PERF=.*" | tail -1)
  if [ -z "$rep" ]; then
    printf '%-22s | %s\n' "$label" "CRASH / no report"
    echo "$out" | grep -iE "SCRIPT ERROR|ERROR|abort|Segmentation|RUN_TIMEOUT|out of memory" | tail -2 | sed 's/^/    /'
    return
  fi
  echo "$rep" | LABEL="$label" DATAFILE="${DATAFILE:-/dev/null}" python3 -c "
import sys,os,json
d=json.loads(sys.stdin.read().split('PERF=',1)[1])
fps=d['fps']; phys=d['physics_ms']; actors=d.get('actors',0)
print('%-22s | %-7.1f | %-8.2f | %-8.2f | %-9.2f | %-8d | %s' % (
    os.environ['LABEL'], fps, d.get('frame_ms',1000.0/max(fps,0.001)), d['cpu_render_ms'], d['process_ms'], d['draw_calls'], actors))
df=os.environ['DATAFILE']
if df!='/dev/null':
    open(df,'a').write('%s %s %s\n' % (actors, phys, fps))"
}

fit_bigO() {  # reads DATAFILE lines: 'actors physics_ms fps' → log-log slope k (time ~ N^k)
  python3 -c "
import math
pts=[]
for line in open('$1'):
    a,p,f=line.split()
    a=float(a); p=float(p); f=float(f)
    if a>0 and p>0 and f>0: pts.append((a,p,f))
if len(pts)<2:
    print('  (need >=2 valid points to fit)'); raise SystemExit
def slope(xs,ys):
    n=len(xs); mx=sum(xs)/n; my=sum(ys)/n
    den=sum((x-mx)**2 for x in xs)
    return (sum((x-mx)*(y-my) for x,y in zip(xs,ys))/den) if den else 0.0
lx=[math.log(a) for a,p,f in pts]
kf=slope(lx,[math.log(1000.0/f) for a,p,f in pts])   # frametime = 1000/fps
kp=slope(lx,[math.log(p) for a,p,f in pts])
print('BIG-O FIT  (time ~ N^k; log-log slope over %d points, N=%d..%d):' % (len(pts),int(min(a for a,_,_ in pts)),int(max(a for a,_,_ in pts))))
print('  frametime(1/fps) vs actors:  k = %.2f' % kf)
print('  physics_ms       vs actors:  k = %.2f' % kp)
lab=lambda k: 'O(N) linear' if k<1.25 else ('O(N log N)' if k<1.5 else ('super-linear' if k<1.8 else 'O(N^2) quadratic'))
print('  => frametime scales %s ; physics %s' % (lab(kf),lab(kp)))"
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
  scaling)
    # Vary ONLY the actor count (LA_SPAWN_SCALE scales spawn counts + breeding caps; grid/res/effects
    # held fixed) and fit the empirical Big-O so a super-linear hotspot shows up as k>1 immediately.
    DATAFILE="$(mktemp)"; export DATAFILE
    for s in 0.25 0.5 1.0 1.5 2.0; do run_one "scale=${s}" "LA_SPAWN_SCALE=${s}" ""; done
    printf -- '-%.0s' {1..80}; printf '\n'
    fit_bigO "$DATAFILE"
    rm -f "$DATAFILE"; unset DATAFILE
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
