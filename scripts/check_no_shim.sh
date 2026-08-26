#!/usr/bin/env bash
# A SHIM IS NOT KEPT, IT IS DELETED. Two arms, because either alone is dodgeable.
#   1  THE CONFESSION: a comment saying a thing exists to keep call sites reading the same.
#   2  THE SHAPE: a private forwarder to another object's identically-named method, or a same-file
#      pair where one name wraps the other, underscores stripped. A PUBLIC forwarder is a facade.
# EXIT 0 clean - 1 a shim - 2 could not run, never a silent pass.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh" 2>/dev/null || true
. "$ROOT/scripts/lib_ceiling.sh" 2>/dev/null || true
command -v require_tool >/dev/null 2>&1 && require_tool rg
command -v require_tool >/dev/null 2>&1 && require_tool python3
SCAN="$ROOT/addons/local_agents"
[ -d "$SCAN" ] || { echo "check_no_shim: MISSING $SCAN — a gate that examines nothing is not a gate." >&2; exit 2; }
fail=0

# Word-boundaried on purpose: "Nagashima" and "shimmer" are not confessions.
CONFESSION='\bshims?\b|\bfor compatibility\b|\bbackwards? compat|\bso (the )?call sites\b|\blegacy path\b|\bexists to look like\b|\bkept for compatibility\b'
hits="$(rg -n -i --glob '!**/thirdparty/**' -g '*.gd' -g '*.cpp' -g '*.hpp' -g '*.glsl' -g '*.glsli' \
        -e "$CONFESSION" "$SCAN" 2>/dev/null || true)"
if [ -n "$hits" ]; then
  echo "check_no_shim: A COMMENT ADMITS A SHIM. Delete the thing, not the sentence." >&2
  printf '%s\n' "$hits" >&2
  fail=1
fi

fwd="$(python3 - "$SCAN" <<'PY'
import pathlib, re, sys
out = []
for f in sorted(pathlib.Path(sys.argv[1]).rglob("*.gd")):
    if "/thirdparty/" in str(f):
        continue
    lines = f.read_text(errors="ignore").split("\n")
    for i, ln in enumerate(lines):
        m = re.match(r"^(?:static )?func ([a-zA-Z_][a-zA-Z0-9_]*)\((.*?)\)\s*(->\s*[\w\.\[\]]+)?\s*:\s*$", ln)
        if not m:
            continue
        body = lines[i+1].strip() if i + 1 < len(lines) else ""
        after = lines[i+2].strip() if i + 2 < len(lines) else ""
        if after and not after.startswith(("func ", "#", "##")):
            continue
        fm = re.match(r"^return ([A-Za-z_][\w\.]*)\.(\w+)\(", body)
        # Stripped, because privatising a public call is the commonest shim: _surface_radius wrapping
        # terrain.surface_radius differs only by the underscore.
        if fm and m.group(1).startswith("_") and fm.group(2).lstrip("_") == m.group(1).lstrip("_"):
            out.append(f"{f}:{i+1}  {m.group(1)} forwards to {fm.group(1)}.{fm.group(2)}")
        # Same file, one name wrapping the other: `convert` whose whole body is `return _convert(...)`.
        sm = re.match(r"^return (_?\w+)\(", body)
        if sm and sm.group(1) != m.group(1) and sm.group(1).lstrip("_") == m.group(1).lstrip("_"):
            out.append(f"{f}:{i+1}  {m.group(1)} wraps {sm.group(1)} in the same file")
print("\n".join(out))
PY
)"
# A RATCHET, because the standing population is larger than one lane may honestly clear: the confession
# arm is zero-tolerance, this one may only FALL. A rise fails for everyone; slack fails the integrator,
# who banks the lower number.
CEIL_FILE="$ROOT/docs/SHIM_CEILING"
[ -f "$CEIL_FILE" ] || { echo "check_no_shim: no ceiling at docs/SHIM_CEILING." >&2; exit 2; }
ceil="$(rg -N -e '^[0-9]+$' "$CEIL_FILE" 2>/dev/null | head -1)"
case "$ceil" in "" | *[!0-9]*) echo "check_no_shim: docs/SHIM_CEILING carries no number." >&2; exit 2 ;; esac
n=0
[ -n "$fwd" ] && n="$(printf '%s\n' "$fwd" | rg -c . || echo 0)"
if [ "$n" -gt "$ceil" ]; then
  echo "check_no_shim: PRIVATE FORWARDERS rose to $n against a ceiling of $ceil." >&2
  echo "               A forwarder is a second name for one thing. Call the owner directly." >&2
  printf '%s\n' "$fwd" >&2
  fail=1
elif [ "$n" -lt "$ceil" ] && [ "$(ceiling_strict "$ROOT" 2>/dev/null || echo 0)" = "1" ]; then
  echo "check_no_shim: $n forwarders against a ceiling of $ceil — write the tighter number." >&2
  fail=1
fi

[ "$fail" -ne 0 ] && { echo "check_no_shim: FAILED." >&2; exit 1; }
echo "check_no_shim: OK (no confessed shim; $n private forwarder(s) against a ceiling of $ceil)."
