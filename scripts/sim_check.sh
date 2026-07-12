#!/usr/bin/env bash
# One-command behavioural verify: run the sim off-screen for N frames and print a clean PASS/FAIL line plus
# the aggregates I check constantly — SCRIPT ERRORs (excluding the benign get_spirv import artifact), the
# get_spirv count (must be 0 after a proper --import), fps, biomass, creatures, fire_cells — instead of the
# grep -oE dance. Wraps run_sim_offscreen.sh (so it's window-parked + focus-safe + silent audio).
#
#   scripts/sim_check.sh                                  # 300 frames, current dir, --sandbox
#   scripts/sim_check.sh --path ../la-foo --frames 800    # a worktree, longer
#   scripts/sim_check.sh --frames 1200 -- --auto-volcano  # pass extra sim flags after --
#
# Exit 0 = PASS (no errors, no get_spirv, biomass>0 i.e. field alive), 1 = FAIL. Full log: $LA_CHECK_LOG
# (default /tmp/sim_check.log).
set -uo pipefail
DIR="."; FRAMES=300; EXTRA=()
while [ $# -gt 0 ]; do
  case "$1" in
    --path) DIR="$2"; shift 2;;
    --frames) FRAMES="$2"; shift 2;;
    --) shift; EXTRA=("$@"); break;;
    *) EXTRA+=("$1"); shift;;
  esac
done
SELF="$(cd "$(dirname "$0")" && pwd)"
LOG="${LA_CHECK_LOG:-/tmp/sim_check.log}"
# Default to --sandbox unless the caller already picked a mode.
MODE=""; case " ${EXTRA[*]-} " in *" --campaign "*|*" --sandbox "*) ;; *) MODE="--sandbox";; esac

"$SELF/run_sim_offscreen.sh" --path "$DIR" addons/local_agents/scenes/simulation/voxel/VoxelWorld.tscn \
  -- $MODE --run-frames="$FRAMES" "${EXTRA[@]-}" >"$LOG" 2>&1
RC=$?

get() { grep -oE "\"$1\":$2" "$LOG" | tail -1 | grep -oE '[0-9.]+' | tail -1; }
ERRORS=$(grep 'SCRIPT ERROR' "$LOG" | grep -vc get_spirv)
SPIRV=$(grep -c 'get_spirv' "$LOG")
NANS=$(grep -ciE 'nan|is_nan|inf' "$LOG")
FPS=$(get fps '\{"cur":[0-9.]+'); BIO=$(get biomass_total '[0-9.]+'); CRE=$(get creatures '[0-9]+')
FIRE=$(get fire_cells '[0-9]+'); MIN=$(get mineral_total '[0-9]+')

PASS=1
[ "${ERRORS:-0}" -gt 0 ] && PASS=0
[ "${SPIRV:-0}" -gt 0 ] && PASS=0
[ -z "${BIO:-}" ] && PASS=0                     # no SIM_REPORT / field dead
[ "${RC:-1}" -ne 0 ] && PASS=0
awk "BEGIN{exit !(${BIO:-0} > 0)}" || PASS=0    # biomass>0 = GPU field actually ran

VERDICT=$([ "$PASS" -eq 1 ] && echo PASS || echo FAIL)
echo "[$VERDICT] errors=$ERRORS get_spirv=$SPIRV rc=$RC | fps=${FPS:-?} biomass=${BIO:-DEAD} creatures=${CRE:-?} fire_cells=${FIRE:-?} mineral=${MIN:-?}"
[ "$PASS" -eq 1 ] || echo "  ↳ first errors:" && grep 'SCRIPT ERROR' "$LOG" | grep -v get_spirv | head -3
exit $([ "$PASS" -eq 1 ] && echo 0 || echo 1)
