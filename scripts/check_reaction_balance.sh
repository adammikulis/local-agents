#!/usr/bin/env bash
# =====================================================================================================
# REACTION BALANCE GATE — a record that creates or destroys matter must not be shippable.
#
# WHY THIS EXISTS. The DEFS reaction engine was a rate table, not a chemistry. `rec()` took `reactants[]`
# and `products[]` as two independent lists of hand-written coefficients with nothing relating them, and
# nothing validated them at any point. Two consequences shipped:
#
#   * R15 decompose consumed 0.8 O2 per 1.0 CO2 produced — 18% under-oxidised, creating oxygen every
#     cycle. It was found by a person reading the table, and fixed by setting two constants equal by hand.
#   * R11 and R12 used the RELAX_TARGET rate model, which had NO REACTANT. reactions_sphere3d.glsl skipped
#     the entire cap-and-debit block for it, so only the product credit ran. Every carbon atom that has
#     ever existed in this simulation was conjured by R12, at +6.5 units per field step.
#
# Conservation was asserted in comments and enforced nowhere, and a rule that lives only in a comment has
# now been broken here twice. This is the enforcement. It is the sibling of check_physical_constants.sh:
# that one keeps the kernels' copies of real-matter values equal to the authority; this one keeps every
# reaction honest about what it is made of.
#
# WHAT IT CHECKS (the detail lives in reactions/ReactionBalance.gd, which is also what the runtime calls):
#   1. every record balances in carbon, nitrogen, h2o, mineral and oxidant (O2-equivalents);
#   2. a record with products and NO reactant is refused outright, in those words;
#   3. TEMP / LIGHT / WINDSPEED / FIRE are drivers, not substances, and cannot be consumed or produced;
#   4. a slot with no declared composition is refused rather than silently treated as massless;
#   5. the GDScript slot enum matches the kernel's #defines, and every slot a record names actually has a
#      read_ch / add_ch branch. Slots 5 (FUEL) and 6 (FIRE) were declared in both enums with no branch in
#      either ladder, so they read 0 and their writes vanished — this catches that class of drift.
#
# EXIT CODES.  0 = clean.  1 = a violation.  2 = the gate COULD NOT RUN (missing godot, missing runner,
# no output, or a table that parsed to zero records). 2 is distinct on purpose: this repo has already
# shipped three gates that reported a pass while examining zero files, because a missing tool made the
# check vacuous. A gate that cannot run must fail, never pass.
# =====================================================================================================
set -uo pipefail

# Pure-bash, no `dirname`: this must still resolve when PATH is broken, or the missing-tool check below
# never gets a chance to report exit 2.
SCRIPT_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
# shellcheck source=lib_require.sh
source "$SCRIPT_DIR/lib_require.sh"
require_tool godot
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

RUNNER="$SCRIPT_DIR/check_reaction_balance.gd"
if [[ ! -f "$RUNNER" ]]; then
  echo "ERROR: check_reaction_balance.sh cannot find its runner at $RUNNER." >&2
  echo "       Refusing to report a pass on zero records." >&2
  exit 2
fi

OUT="$(godot --headless --path "$REPO_ROOT" -s "$RUNNER" 2>&1)"
# Godot's own exit code is not reliably the script's `quit(N)` on every platform, so the verdict is read
# from the structured marker the runner prints as its last line. No marker = the gate did not run.
SUMMARY="$(printf '%s\n' "$OUT" | grep -o 'REACTION_BALANCE=.*' | tail -n 1)"
if [[ -z "$SUMMARY" ]]; then
  echo "$OUT"
  echo "ERROR: the reaction-balance runner produced no REACTION_BALANCE= marker, so nothing was checked." >&2
  exit 2
fi

RECORDS="$(printf '%s' "$SUMMARY" | grep -oE '"records":[-0-9]+' | grep -oE '[-0-9]+$')"
VIOLATIONS="$(printf '%s' "$SUMMARY" | grep -oE '"violations":[-0-9]+' | grep -oE '[-0-9]+$')"

if [[ -z "${RECORDS:-}" || -z "${VIOLATIONS:-}" || "$VIOLATIONS" -lt 0 || "$RECORDS" -le 0 ]]; then
  printf '%s\n' "$OUT" | grep -E 'REACTION_BALANCE' || true
  echo "ERROR: the reaction table parsed to $RECORDS record(s); the gate examined nothing." >&2
  exit 2
fi

if [[ "$VIOLATIONS" -gt 0 ]]; then
  printf '%s\n' "$OUT" | grep -E 'REACTION_BALANCE_VIOLATION' || true
  echo "reaction-balance check FAILED: $VIOLATIONS violation(s) across $RECORDS record(s)." >&2
  echo "A reaction must not create or destroy matter. Fix the record, or declare the substance it moves in" >&2
  echo "LAReactionBalance.composition()." >&2
  exit 1
fi

echo "reaction-balance check passed: $RECORDS records, 0 violations."
exit 0
