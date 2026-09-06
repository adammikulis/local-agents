#!/usr/bin/env bash
# THE FIELD STEP IS DERIVED FROM THE STATE IT OPENS IN, NEVER DECLARED: no constant step, a Courant
# condition per cell and a free-fall bound on the box, one Courant number, and no substrate rate
# reading the day length.
# Exit 0 = clean, 1 = violation, 2 = the gate could not run.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib_require.sh
source "$SCRIPT_DIR/lib_require.sh"
require_tool rg

ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
STEP_FILE="addons/local_agents/sim/material/MaterialFieldSphereStep3D.gd"
CLOCK_FILE="addons/local_agents/sim/SimClock.gd"
FLUX="addons/local_agents/sim/material/kernels3d/flux.glsl"
GEN="addons/local_agents/sim/material/kernels3d/generated.glsli"
SIM_DIR="addons/local_agents/sim"
KERNEL_DIR="addons/local_agents/sim/material/kernels3d"

for f in "$STEP_FILE" "$CLOCK_FILE" "$FLUX" "$GEN"; do
  if [[ ! -f "$ROOT/$f" ]]; then
    echo "ERROR: check_step_quantum.sh cannot find $f" >&2
    echo "       Refusing to report a pass when the file it gates is missing." >&2
    exit 2
  fi
done
for d in "$SIM_DIR" "$KERNEL_DIR"; do
  if [[ ! -d "$ROOT/$d" ]]; then
    echo "ERROR: check_step_quantum.sh cannot find $d" >&2
    exit 2
  fi
done

violations=0

# --- 1. the quantum is DERIVED, not declared ------------------------------------------------------------
if rg -q '^const SIM_SECONDS_PER_STEP' "$ROOT/$STEP_FILE"; then
  echo "FAIL  $STEP_FILE declares a constant simulated-seconds-per-step."
  echo "      The step is what the state affords: the advective Courant condition over the active cells,"
  echo "      and the free-fall time across the finest cell. A declared one is a number nobody derived."
  violations=$((violations + 1))
fi
body="$(awk '
  /^static func seconds_per_step\(\)/ { grab = 1; next }
  grab && /^(static func|func|const|var|#|##)/ { grab = 0 }
  grab { print }
' "$ROOT/$STEP_FILE" | tr -d '[:space:]')"
if [[ "$body" != "return_dt_s" ]]; then
  echo "FAIL  $STEP_FILE: seconds_per_step() must be exactly 'return _dt_s'."
  echo "      Found: ${body:-<no body>}"
  echo "      Any other term makes the step a function of something the derivation did not measure."
  violations=$((violations + 1))
fi
if ! rg -q '^static func publish_step_seconds' "$ROOT/$STEP_FILE"; then
  echo "FAIL  $STEP_FILE has no publish_step_seconds(): nothing can hand the derived step to the clock."
  violations=$((violations + 1))
fi

# --- 2. the derivation is a Courant condition on the cell's own state --------------------------------
if ! rg -q 'float dt = rate > 0.0 \? LA_COURANT_LIMIT / rate' "$ROOT/$FLUX"; then
  echo "FAIL  $FLUX: la_row_dt does not divide the Courant number by the cell's own rate, so the step"
  echo "      is not the Courant condition on the state."
  violations=$((violations + 1))
fi
if ! rg -q 'sqrt\(2.0 \* COURANT \* edge / gm\)' "$ROOT/$STEP_FILE"; then
  echo "FAIL  $STEP_FILE: the box states no free-fall bound, so a world whose cells all read INF has"
  echo "      no step at all and nothing is ever seen to fall."
  violations=$((violations + 1))
fi

# --- 3. ONE Courant number ---------------------------------------------------------------------------
if ! rg -q '^const COURANT: float = ' "$ROOT/$STEP_FILE"; then
  echo "FAIL  $STEP_FILE declares no 'const COURANT: float ='; generated.glsli is emitted from it."
  violations=$((violations + 1))
fi
dup="$(rg -n --no-heading 'LA_COURANT_LIMIT *=' --glob "$KERNEL_DIR/**/*.glsl" --glob "$KERNEL_DIR/**/*.glsli" \
  --glob "!$GEN" "$ROOT" 2>/dev/null)"
if [[ -n "$dup" ]]; then
  echo "FAIL  a second Courant number is declared in the kernels:"
  echo "$dup" | sed "s#^$ROOT/#      #"
  violations=$((violations + 1))
fi

# --- 4. nothing in the substrate reads the day-length knob ----------------------------------------------
hits="$(rg -n --no-heading 'day_length' \
  --glob "$SIM_DIR/**/*.gd" --glob "$KERNEL_DIR/**/*.glsl" --glob "$KERNEL_DIR/**/*.glsli" \
  --glob "!$CLOCK_FILE" "$ROOT" 2>/dev/null)"
if [[ -n "$hits" ]]; then
  echo "FAIL  day_length is read inside the simulation substrate:"
  echo "$hits" | sed "s#^$ROOT/#      #"
  echo
  echo "      The day length is the body's rotation period (LASimClock.day_length), not an input to any"
  echo "      rate. A planet that spins slower gets MORE steps per day; its chemistry per step does not move."
  violations=$((violations + 1))
fi

if [[ $violations -gt 0 ]]; then
  exit 1
fi
echo "Step-quantum check passed (the step is derived and published; one Courant number; no substrate rate reads day_length)."
exit 0
