#!/usr/bin/env bash
# A GATE ON THE FORMULA, NOT ON THE VALUES.
#
# WHY IT EXISTS, and it is the lesson rc_shared.glsli states in its own header: "The RC_* values were never
# the problem — every copy was correctly bound to LAPhysical and the physical-constants gate passed on all of
# them. THE COMPOSITION diverged, which no value gate can see. That is the general lesson: a gate on
# constants does not gate the FORMULA they sit in."
#
# A cell's volumetric heat capacity was written NINE times: five in GLSL (in four mutually incompatible
# formulas) and four in GDScript. Two of the GDScript copies were the two halves of one subtraction — the
# energy ledger differences a BOOKED number from LAMaterialFieldEnergyBudget3D against its own STOCK — so
# their disagreement was published as planetary energy drift for as long as it existed. check_physical_
# constants.sh was green throughout, because every copy read the right numbers and put them in a different
# expression.
#
# So this gate asks a structural question instead of a numeric one:
#   1. Is an RC_* volumetric-capacity constant DECLARED anywhere but kernels3d/rc_shared.glsli?
#   2. Is LAPhysical.VOL_HEAT_CAP_*_J_M3K READ anywhere but material/HeatCapacity.gd?
# Either means a tenth copy is being born. There is one definition per side of the GPU boundary and they are
# held equal by a comment contract in both files; that contract is only enforceable if nothing else writes
# the mix down.
#
# Exit 0 = clean, 1 = violation, 2 = the gate could not run (see lib_require.sh: a missing tool must never
# read as a pass — two gates in this repo reported success on ZERO files for months).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib_require.sh
source "$SCRIPT_DIR/lib_require.sh"
require_tool rg

ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GLSL_SSOT="addons/local_agents/sim/material/kernels3d/rc_shared.glsli"
GD_SSOT="addons/local_agents/sim/material/HeatCapacity.gd"
AUTHORITY="addons/local_agents/sim/material/PhysicalConstants.gd"

for f in "$GLSL_SSOT" "$GD_SSOT" "$AUTHORITY"; do
  if [[ ! -f "$ROOT/$f" ]]; then
    echo "ERROR: check_heat_capacity_ssot.sh cannot find $f" >&2
    echo "       Refusing to report a pass when the file it gates is missing." >&2
    exit 2
  fi
done

violations=0

# --- 1. RC_* declared outside the shared GLSL include ---------------------------------------------------
# Matches a GLSL const declaration only, so a kernel may still SAY RC_WATER in a comment explaining why it
# does not declare one.
while IFS= read -r hit; do
  file="${hit%%:*}"
  [[ "$file" == "$GLSL_SSOT" ]] && continue
  echo "FAIL $hit"
  echo "     A volumetric heat capacity is declared outside $GLSL_SSOT."
  echo "     Include it and call rc_of() instead. Nine copies of this mix in four different formulas is"
  echo "     what created and destroyed heat at every exchange; the values were never the problem."
  violations=$((violations + 1))
done < <(cd "$ROOT" && rg -n --no-heading \
  'const[[:space:]]+float[[:space:]]+RC_[A-Z_]+[[:space:]]*=' \
  addons/local_agents --glob '*.glsl' --glob '*.glsli' 2>/dev/null)

# --- 2. VOL_HEAT_CAP_*_J_M3K read outside the one GDScript definition ------------------------------------
# The authority may of course declare and derive them; HeatCapacity.gd is the only permitted consumer.
# Tests are excluded deliberately: a test that asserts a value against LAPhysical is checking the authority,
# not forking the model.
while IFS= read -r hit; do
  file="${hit%%:*}"
  [[ "$file" == "$GD_SSOT" || "$file" == "$AUTHORITY" ]] && continue
  case "$file" in addons/local_agents/tests/*) continue ;; esac
  # A doc comment naming the constant is not a use. Strip the file:line prefix and test the code half.
  body="${hit#*:}"; body="${body#*:}"
  trimmed="${body#"${body%%[![:space:]]*}"}"
  case "$trimmed" in \#*|//*|'##'*) continue ;; esac
  echo "FAIL $hit"
  echo "     LAPhysical.VOL_HEAT_CAP_* is read outside $GD_SSOT."
  echo "     Call LAHeatCapacity.cell() / .field() instead. Two of the four GDScript copies of this mix were"
  echo "     the BOOKED and the STOCK sides of one subtraction, so their disagreement WAS the reported drift."
  violations=$((violations + 1))
done < <(cd "$ROOT" && rg -n --no-heading \
  'LAPhysical\.VOL_HEAT_CAP_[A-Z_]+_J_M3K' \
  addons/local_agents --glob '*.gd' 2>/dev/null)

if [[ "$violations" -gt 0 ]]; then
  echo
  echo "Heat-capacity SSOT gate: $violations violation(s)."
  echo "  GLSL  : $GLSL_SSOT     (rc_of)"
  echo "  GDScript: $GD_SSOT   (LAHeatCapacity)"
  echo "Keep the two one edit apart; everything else calls them."
  exit 1
fi

echo "Heat-capacity SSOT gate passed (one GLSL definition, one GDScript definition)."
exit 0
