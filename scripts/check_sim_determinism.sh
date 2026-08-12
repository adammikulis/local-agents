#!/usr/bin/env bash
# ONE RNG FOR THE WORLD, ENFORCED.
#
# WHY IT EXISTS. Godot's global randf()/randi() is seeded from the OS at startup, so every call to it is a
# number nobody can reproduce. Forty-one of them were live across the simulation and creature layers, and
# because LASimRng is a SHARED stream, one subsystem drawing a different NUMBER of times shifts every other
# subsystem's draws with it. Two runs of `sim_run.sh --seed 4242` returned different worlds.
#
# WHAT IT CHECKS, over the simulation-affecting roots only:
#   1. No call to the engine's global RNG (randf/randi/randf_range/randi_range/randfn/randomize).
#   2. Any RandomNumberGenerator built here is given an explicit seed in the same file. A bare
#      RandomNumberGenerator.new() is seeded from the OS and is the same defect wearing an object.
#
# PRESENTATION IS EXEMPT BY PATH, NEVER BY ANNOTATION. Music, audio jitter, camera shake and the streamer
# avatar do not change what the world does, and seeding them would make every playthrough sound and look
# identical. Those paths are listed below; nothing else gets an exemption.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh" 2>/dev/null || true
command -v require_tool >/dev/null 2>&1 && require_tool rg

SCAN_ROOTS=(
  "$ROOT/addons/local_agents/sim"
  "$ROOT/addons/local_agents/creatures"
  "$ROOT/addons/local_agents/game/world"
)
# Presentation, or the seeded source itself.
EXEMPT_RE='/addons/local_agents/sim/streamer/|/addons/local_agents/tests/|/creatures/sim/SimRng.gd$|/game/world/VoxelAudioController.gd$'

for d in "${SCAN_ROOTS[@]}"; do
  [ -d "$d" ] || { echo "check_sim_determinism: MISSING scan root $d." >&2; exit 2; }
done

FILES=$(rg --files "${SCAN_ROOTS[@]}" -g '*.gd' 2>/dev/null | grep -vE "$EXEMPT_RE" || true)
if [ -z "$FILES" ]; then
  echo "check_sim_determinism: ZERO files matched. Refusing to report a pass on nothing." >&2
  exit 2
fi
COUNT=$(printf '%s\n' "$FILES" | wc -l | tr -d ' ')

fail=0

# 1. The engine's global RNG. `[^A-Za-z0-9_.]` before the name keeps rng.randf() / _rng.randi_range() out.
bare=$(printf '%s\n' "$FILES" | tr '\n' '\0' \
       | xargs -0 grep -nE '(^|[^A-Za-z0-9_.])(randf|randi|randf_range|randi_range|randfn|randomize)[[:space:]]*\(' \
       2>/dev/null | grep -vE '^[^:]*:[0-9]+:[[:space:]]*#' || true)
if [ -n "$bare" ]; then
  echo "check_sim_determinism: GLOBAL RNG IN A SIMULATION PATH. Draw from LASimRng instead —" >&2
  echo "  LASimRng.for_domain(\"life\") for ecology/creatures, LASimRng.for_domain(\"planet\") for" >&2
  echo "  weather/tectonics/the ambient director, LASimRng.shared() for disasters and world matter." >&2
  echo "$bare" >&2
  fail=1
fi

# 2. An unseeded RandomNumberGenerator is the same defect wearing an object.
while IFS= read -r f; do
  grep -q 'RandomNumberGenerator.new()' "$f" 2>/dev/null || continue
  grep -qE '\.(seed|state)[[:space:]]*=' "$f" 2>/dev/null && continue
  echo "check_sim_determinism: $f builds a RandomNumberGenerator and never seeds it." >&2
  fail=1
done <<< "$FILES"

if [ "$fail" -ne 0 ]; then
  echo "check_sim_determinism: FAILED." >&2
  exit 1
fi
echo "Sim-determinism gate passed (${COUNT} files, no global RNG, every generator seeded)."
