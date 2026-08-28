#!/usr/bin/env bash
# REACTION BALANCE GATE — a record that creates or destroys matter must not be shippable. Conservation
# asserted in a comment is enforced nowhere, and this repo has broken that rule twice: a decomposition
# under-oxidised per cycle, and a rate model with NO REACTANT whose product credit ran while the kernel
# skipped the whole cap-and-debit block. Sibling of check_physical_constants.sh: that keeps the kernels'
# copies of real-matter values equal to the authority, this keeps every reaction honest about what it is
# made of.

# WHAT IT CHECKS, the detail living in reactions/ReactionBalance.gd, which is what the runtime calls:
#   1. every record balances in ATOMS — C, N, H, O, Ca, Si — after converting each coefficient from
#      channel units to moles, a channel unit not being a mole and the two differing by up to 6484x;
#   2. a record with products and NO reactant is refused outright, in those words;
#   3. TEMP / LIGHT / WINDSPEED / FIRE are drivers, not substances, so cannot be consumed or produced;
#   4. a slot with no declared composition is refused rather than treated as massless;
#   5. the GDScript slot enum matches the kernel's #defines, and every slot a record names has a
#      read_ch / add_ch branch — a slot declared in both enums with no branch reads 0 and its writes
#      vanish.

# EXIT 0 clean · 1 a violation · 2 could not run (missing godot, missing runner, no output, or a table
# that parsed to zero records). A gate that cannot run must fail, never pass.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_godot.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_capture.sh"
la_examined "$(basename "$0")" || exit $?

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

if la_cap_dir >/dev/null; then
  OUT="$(la_headless reaction_balance)" || exit 2
else
  OUT="$(la_godot --headless --path "$REPO_ROOT" -s "$RUNNER" 2>&1)"
fi
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
