#!/usr/bin/env bash
# A FIELD STEP IS A FIXED QUANTUM OF SIMULATED TIME. THE DAY LENGTH IS DERIVED FROM IT, NEVER AN INPUT TO IT.
#
# Evaporation, pyrolysis, decomposition, photosynthesis, rain autoconversion, the thermal diffusion number,
# the transport Courant factor, the geotherm flux and the plate drift rate all multiply by
# real_seconds_per_step(). A day length reaching that function rescales the whole chemistry of the planet.
#
# Three checks:
#   1. MaterialFieldSphereStep3D.gd declares `const SIM_SECONDS_PER_STEP`.
#   2. real_seconds_per_step() returns exactly that constant — no other identifier in its body.
#   3. DAY_LENGTH appears nowhere under addons/local_agents/sim/ except SimClock.gd, and nowhere in the
#      kernels. No carve-outs: a substrate rate reading the day-length knob is the defect itself.
#
# Exit 0 = clean, 1 = violation, 2 = the gate could not run.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib_require.sh
source "$SCRIPT_DIR/lib_require.sh"
require_tool rg

ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
STEP_FILE="addons/local_agents/sim/material/MaterialFieldSphereStep3D.gd"
CLOCK_FILE="addons/local_agents/sim/SimClock.gd"
SIM_DIR="addons/local_agents/sim"
KERNEL_DIR="addons/local_agents/sim/material/kernels3d"

for f in "$STEP_FILE" "$CLOCK_FILE"; do
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

# --- 1. the quantum is declared ------------------------------------------------------------------------
if ! rg -q '^const SIM_SECONDS_PER_STEP: float = ' "$ROOT/$STEP_FILE"; then
  echo "FAIL  $STEP_FILE declares no 'const SIM_SECONDS_PER_STEP: float ='."
  echo "      The substrate needs ONE explicit simulated-seconds-per-step. Without it the step quantum is"
  echo "      whatever the caller's clock happens to be, which is how the day length got into the chemistry."
  violations=$((violations + 1))
fi

# --- 2. real_seconds_per_step() returns it and nothing else ---------------------------------------------
body="$(awk '
  /^static func real_seconds_per_step\(\)/ { grab = 1; next }
  grab && /^(static func|func|const|var|#|##)/ { grab = 0 }
  grab { print }
' "$ROOT/$STEP_FILE" | tr -d '[:space:]')"
if [[ "$body" != "returnSIM_SECONDS_PER_STEP" ]]; then
  echo "FAIL  $STEP_FILE: real_seconds_per_step() must be exactly 'return SIM_SECONDS_PER_STEP'."
  echo "      Found: ${body:-<no body>}"
  echo "      Any other term makes the step quantum a function of something else, and every reaction rate in"
  echo "      the substrate multiplies by this function."
  violations=$((violations + 1))
fi

# --- 3. nothing in the substrate reads the day-length knob ----------------------------------------------
hits="$(rg -n --no-heading 'DAY_LENGTH' \
  --glob "$SIM_DIR/**/*.gd" --glob "$KERNEL_DIR/**/*.glsl" --glob "$KERNEL_DIR/**/*.glsli" \
  --glob "!$CLOCK_FILE" "$ROOT" 2>/dev/null)"
if [[ -n "$hits" ]]; then
  echo "FAIL  DAY_LENGTH is read inside the simulation substrate:"
  echo "$hits" | sed "s#^$ROOT/#      #"
  echo
  echo "      The day length is the body's rotation period (LASimClock.DAY_LENGTH), not an input to any"
  echo "      rate. A planet that spins slower gets MORE steps per day; its chemistry per step does not move."
  violations=$((violations + 1))
fi

if [[ $violations -gt 0 ]]; then
  exit 1
fi
echo "Step-quantum check passed (fixed SIM_SECONDS_PER_STEP; no substrate rate reads DAY_LENGTH)."
exit 0
