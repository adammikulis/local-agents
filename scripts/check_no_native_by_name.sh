#!/usr/bin/env bash
# The compiled GDExtension is a hard dependency, so a native class is a TYPED identifier, never a
# string looked up at runtime. A by-name reach is a fallback: it compiles with no binary present and
# degrades silently when the lookup returns null.
#   1  ClassDB.instantiate( or class_get_integer_constant( anywhere under addons/local_agents/sim
#   2  LANativeTables anywhere in the tree
# EXIT 0 clean · 1 a by-name reach · 2 could not run, never a silent pass.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh" 2>/dev/null || true
command -v require_tool >/dev/null 2>&1 && require_tool rg
SIM="$ROOT/addons/local_agents/sim"
TREE="$ROOT/addons/local_agents"
for d in "$SIM" "$TREE"; do
  [ -d "$d" ] || { echo "check_no_native_by_name: MISSING $d — a gate that examines nothing is not a gate." >&2; exit 2; }
done
fail=0

byname="$(rg -n --glob '!**/thirdparty/**' -e 'ClassDB\.instantiate\(' -e 'class_get_integer_constant\(' "$SIM" 2>/dev/null || true)"
if [ -n "$byname" ]; then
  echo "check_no_native_by_name: A NATIVE CLASS REACHED BY NAME under sim/. Use the typed identifier." >&2
  printf '%s\n' "$byname" >&2
  fail=1
fi

tables="$(rg -n --glob '!**/thirdparty/**' --glob "!${BASH_SOURCE[0]##*/}" \
  -e 'LANativeTables' "$TREE" "$ROOT/scripts" "$ROOT/docs" "$ROOT/CLAUDE.md" "$ROOT/HANDOFF.md" 2>/dev/null || true)"
if [ -n "$tables" ]; then
  echo "check_no_native_by_name: LANativeTables is DELETED. Name LASubstances, LABodySeeds, ... directly." >&2
  printf '%s\n' "$tables" >&2
  fail=1
fi

[ "$fail" -ne 0 ] && { echo "check_no_native_by_name: FAILED." >&2; exit 1; }
echo "check_no_native_by_name: OK (every native class named as a typed identifier)."
