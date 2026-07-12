#!/usr/bin/env bash
# VISUAL REGRESSION SUITE — capture every visual surface of the sim to a labeled PNG set so render regressions
# (floating cubes, broken shaders, missing ice caps, black sky, swiss-cheese terrain) are caught SYSTEMATICALLY,
# not by chance. sim_check.sh gates the NUMBERS; this gates the LOOK. Review the PNGs (Read them / open the dir /
# the contact sheet) after any render-affecting change, and compare against a committed baseline set.
#
#   scripts/screenshot_suite.sh                      # quick set (orbit, ground, volcano) — the regression-prone few
#   scripts/screenshot_suite.sh full                 # every scenario
#   scripts/screenshot_suite.sh full --path ../wt --out DIR
#
# Terrain is seeded (LA_SIM_SEED=1337) so the WORLD is reproducible shot-to-shot; disasters use Godot's global
# RNG so their placement varies (a known limit — see disaster-load-unseeded-rng). Each shot: 0 errors + a
# non-trivial PNG => PASS. Builds a contact-sheet montage if ImageMagick `montage` is present.
set -uo pipefail
SELF="$(cd "$(dirname "$0")" && pwd)"
SET="${1:-quick}"; [ "$SET" = "--path" ] && SET="quick"   # allow flags-first
DIR="."; OUT="/private/tmp/claude-501/-Users-adammikulis-Documents-repos-godot-local-agents/69654869-7907-4b7e-92ed-b2ce1104a628/scratchpad/shots/suite"
shift 2>/dev/null || true
while [ $# -gt 0 ]; do case "$1" in --path) DIR="$2"; shift 2;; --out) OUT="$2"; shift 2;; *) shift;; esac; done
mkdir -p "$OUT"
SCENE="addons/local_agents/scenes/simulation/voxel/VoxelWorld.tscn"
RES="${LA_RES:-1280x800}"

# scenario = "name|extra-sim-flags|shoot-frames". The world-view flags frame the camera; --auto-* fire a disaster
# (disasters fire ~shoot_frames-240, so give them >=520 frames to fire + settle before the shot).
QUICK=(
  "orbit|--farview|300"
  "ground|--water-cam|320"
  "volcano|--auto-volcano|560"          # land-building — the floating-cube regression lives here
)
FULL=(
  "${QUICK[@]}"
  "seavolcano|--auto-seavolcano|600"    # island building from a sea vent
  "barrage|--auto-barrage|560"          # meteor craters (+ can expose caves)
  "thunderstorm|--auto-thunderstorm|900"
  "tornado|--auto-tornado|560"
  "hurricane|--auto-hurricane|560"
  "earthquake|--auto-earthquake|560"
  "solar|--solar-view|300"              # solar-system view: black space + sun + planet
  "creature|--auto-select|320"          # a framed creature + inspector
)
case "$SET" in full) SCENARIOS=("${FULL[@]}");; *) SCENARIOS=("${QUICK[@]}");; esac

echo "[suite] $SET set → $OUT (path=$DIR)"
PASS=0; FAIL=0; SHOTS=()
for row in "${SCENARIOS[@]}"; do
  IFS='|' read -r name flags frames <<<"$row"
  png="$OUT/$name.png"; log="$OUT/$name.log"
  LA_SIM_SEED=1337 LA_RES="$RES" "$SELF/run_sim_offscreen.sh" --path "$DIR" "$SCENE" \
    -- --sandbox $flags --shoot="$png" --shoot-frames="$frames" >"$log" 2>&1
  errs=$(grep 'SCRIPT ERROR' "$log" | grep -vc get_spirv)
  # a real render = the PNG exists and isn't trivially tiny (a blank/failed capture is a few hundred bytes)
  bytes=$(wc -c <"$png" 2>/dev/null || echo 0)
  if [ -s "$png" ] && [ "$bytes" -gt 20000 ] && [ "${errs:-1}" -eq 0 ]; then
    echo "  [ok]   $name  (${bytes} bytes)"; PASS=$((PASS+1)); SHOTS+=("$png")
  else
    echo "  [FAIL] $name  (bytes=$bytes errors=$errs — see $log)"; FAIL=$((FAIL+1))
  fi
done

# Contact sheet for one-glance review (optional — needs ImageMagick).
if command -v montage >/dev/null 2>&1 && [ ${#SHOTS[@]} -gt 0 ]; then
  montage -label '%f' "${SHOTS[@]}" -tile 3x -geometry 480x300+4+4 -background '#111' -fill '#ccc' \
    "$OUT/_contact_sheet.png" 2>/dev/null && echo "[suite] contact sheet → $OUT/_contact_sheet.png"
fi
echo "[suite] done: $PASS ok, $FAIL fail. Review: $OUT/*.png"
exit $([ "$FAIL" -eq 0 ] && echo 0 || echo 1)
