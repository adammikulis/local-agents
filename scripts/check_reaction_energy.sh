#!/usr/bin/env bash
# =====================================================================================================
# REACTION ENERGY GATE — a phase-change loop may not be an energy source.
#
# WHY THIS EXISTS. check_reaction_balance.sh proves every record balances in ATOMS. Nothing proves
# anything about its ENTHALPY, so a record with a wrong sign, a wrong magnitude, or no latent heat at all
# ships silently — and this project has already shipped exactly that: sublimation was DECLARED as its own
# constant rather than derived as fusion + vaporisation, so a traverse of the water cycle released
# 2.433e5 J/kg from nothing. That was found by a person reading the table.
#
# The two checks are the ones a table can answer without running anything:
#   1. HESS'S LAW. Phase changes form loops — water to vapour to snow to water. The enthalpies around a
#      closed loop must sum to zero, or matter can be walked round it as a generator.
#   2. REVERSIBILITY. If A becomes B and B becomes A, the enthalpies must be equal and opposite. A freeze
#      releasing more than its melt absorbs is a perpetual-motion machine with a rate limit.
#   3. HESS ON EVERY RECORD. A record's heat must be the one its own formation enthalpies give, so no
#      module may hand-write one beside the table or leave it at zero.
#   4. INTERNAL ENERGY. The state is internal energy, not enthalpy, so every record carries the net moles
#      of gas it makes and the kernel takes dn_gas R T back off the heat.
#
# EXIT CODES. 0 clean · 1 a violation · 2 the gate could not run (missing godot, missing runner, or a
# table with no phase transfers in it) — never a silent pass.
# =====================================================================================================
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_godot.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_capture.sh"
la_examined "$(basename "$0")" || exit $?

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER_REL="scripts/check_reaction_energy.gd"

# shellcheck source=lib_require.sh
source "$REPO_ROOT/scripts/lib_require.sh" 2>/dev/null || true
if declare -f require_tool >/dev/null 2>&1; then
  require_tool godot
elif ! command -v godot >/dev/null 2>&1; then
  echo "ERROR: godot not on PATH — a gate that cannot run FAILS, it does not pass." >&2
  exit 2
fi
if [[ ! -f "$REPO_ROOT/$RUNNER_REL" ]]; then
  echo "ERROR: runner missing: $RUNNER_REL" >&2
  exit 2
fi

if la_cap_dir >/dev/null; then
  out="$(la_headless reaction_energy)" || exit 2
else
  out="$(cd "$REPO_ROOT" && LA_GODOT_TIMEOUT=120 la_godot --headless --path . -s "res://$RUNNER_REL" 2>&1)"
fi
echo "$out" | grep -E '^REACTION_ENERGY_FAIL=|^REACTION_ENERGY_ERROR|^REACTION_ENERGY=' || true

line="$(echo "$out" | grep -E '^REACTION_ENERGY=' | tail -1)"
if [[ -z "$line" ]]; then
  echo "ERROR: no REACTION_ENERGY marker — the gate did not run to completion." >&2
  echo "$out" | tail -20 >&2
  exit 2
fi
if echo "$line" | grep -q '"violations":-1'; then
  exit 2
fi
if echo "$line" | grep -q '"edges":0'; then
  echo "ERROR: zero phase transfers examined — refusing to report a pass on an empty table." >&2
  exit 2
fi
if echo "$line" | grep -q '"violations":0'; then
  echo "reaction-energy check passed: phase loops close, reverse pairs cancel, every heat is the table's,"
  echo "and the kernel converts each one to internal energy."
  exit 0
fi
echo
echo "A reaction heat that is not the table's is a second authority on one number, and a phase-change loop"
echo "that does not sum to zero is an energy source. Derive it from LASubstances rather than adjusting it."
exit 1
