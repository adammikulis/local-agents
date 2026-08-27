#!/usr/bin/env bash
# The compiled GDExtension is a hard dependency, so a native class is a TYPED identifier, never a
# string looked up at runtime, and never a thing we ask whether it is there.
#   1  ClassDB.instantiate( or class_get_integer_constant( under addons/local_agents/sim
#   2  LANativeTables anywhere
#   3  class_exists( / has_singleton( naming a class OUR OWN extension registers. The registered set
#      is parsed out of the C++ register file, so an optional third-party extension stays legal and a
#      new native class is covered the day it is registered. A file that calls Engine.register_singleton(
#      or holds the GDExtension is exempt: it owns the registration, so asking is a measurement.
# EXIT 0 clean · 1 a by-name reach · 2 could not run, never a silent pass.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh" 2>/dev/null || true
command -v require_tool >/dev/null 2>&1 && require_tool rg
command -v require_tool >/dev/null 2>&1 && require_tool python3
SIM="$ROOT/addons/local_agents/sim"
TREE="$ROOT/addons/local_agents"
REG="$TREE/gdextensions/localagents/src/LocalAgentsRegister.cpp"
for p in "$SIM" "$TREE" "$REG"; do
  [ -e "$p" ] || { echo "check_no_native_by_name: MISSING $p — a gate that examines nothing is not a gate." >&2; exit 2; }
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

GUARD_OUT="$(mktemp)"
trap 'rm -f "$GUARD_OUT"' EXIT
python3 - "$REG" "$TREE" > "$GUARD_OUT" <<'PY'
import pathlib, re, sys
reg = pathlib.Path(sys.argv[1]).read_text(errors="ignore")
owned = set(re.findall(r"register_class<(\w+)>", reg))
owned |= set(re.findall(r"register_singleton\(StringName\([\x22\x27](\w+)[\x22\x27]\)", reg))
if not owned:
    sys.stderr.write("parsed no registered class from the register file\n")
    sys.exit(2)
call = re.compile(r"(?:ClassDB\.class_exists|Engine\.has_singleton)\(\s*([^)]*?)\s*\)")
quoted = re.compile(r"&?[\x22\x27](\w+)[\x22\x27]")
ident = re.compile(r"[A-Za-z_][\w.]*\Z")
out = []
for f in sorted(pathlib.Path(sys.argv[2]).rglob("*.gd")):
    if "/thirdparty/" in str(f):
        continue
    src = f.read_text(errors="ignore")
    if "Engine.register_singleton(" in src or ": GDExtension" in src:
        continue
    for i, ln in enumerate(src.split("\n"), 1):
        for m in call.finditer(ln):
            arg = m.group(1)
            q = quoted.fullmatch(arg)
            if q:
                if q.group(1) in owned:
                    out.append("%s:%d  asks whether %s is registered" % (f, i, q.group(1)))
            elif ident.match(arg):
                out.append("%s:%d  asks by an indirect name (%s)" % (f, i, arg))
print("\n".join(out))
PY
rc=$?
guards="$(cat "$GUARD_OUT")"
[ "$rc" -eq 2 ] && { echo "check_no_native_by_name: could not derive the registered set." >&2; exit 2; }
if [ -n "$guards" ]; then
  echo "check_no_native_by_name: AN EXISTENCE GUARD ON OUR OWN NATIVE CLASS. The binary is a hard" >&2
  echo "                        dependency, so the false branch is unreachable. Delete both." >&2
  printf '%s\n' "$guards" >&2
  fail=1
fi

[ "$fail" -ne 0 ] && { echo "check_no_native_by_name: FAILED." >&2; exit 1; }
echo "check_no_native_by_name: OK (native classes named as typed identifiers; no existence guard)."
