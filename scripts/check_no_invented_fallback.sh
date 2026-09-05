#!/usr/bin/env bash
# NO INVENTED FALLBACK — a duck-typed probe may not stand in a number for a measurement it could not
# take. The shape:
#     var t: float = 15.0
#     if _field.has_method("temp_at"):
#         t = float(_field.temp_at(_base))
# Rename the method and the branch goes quiet while the caller believes the air is 15 °C. Same defect
# check_no_silent_fallback.sh catches in `.get(key, mirror)` form, and worse: nobody derived the number.

# BANNED: a scalar initialised to a non-empty literal and then assigned inside a has_method() guard,
# WHERE THE RECEIVER IS THE SUBSTRATE. The field is one concrete class, so probing it is never
# polymorphism — the guard is a leftover whose false branch is unreachable until it isn't.
# ALLOWED: an empty default (0.0 / false / ZERO / NAN), which reads as ABSENT rather than as a reading.
# ALSO ALLOWED, hence the receiver scope: genuine dispatch over heterogeneous nodes, like CreatureThink
# asking a food node for `food_mass_per_unit`, where a plant and a carcass really do differ and the
# default is a declared unit contract rather than a measurement somebody guessed.

# SECOND ARM: A QUERY WITH NO EMPTY ANSWER. A float has NAN and a Vector3 has ZERO; `bool` and `int` have
# neither, so a query about the world answering with a literal when its collaborator is missing has
# invented a reading and cannot say so. EcologyService.is_night_at reads "day" with no sun. An ACTION may
# report false -- that is what it did -- so only query-shaped names are counted, under a ratchet.
#
# EXIT 0 none · 1 found · 2 could not run.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$REPO_ROOT/scripts/lib_ceiling.sh" 2>/dev/null || true
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 not on PATH — a gate that cannot run FAILS." >&2; exit 2; }
[ -d "$REPO_ROOT/addons/local_agents" ] || { echo "ERROR: source root missing." >&2; exit 2; }
CEIL_FILE="$REPO_ROOT/docs/INVENTED_QUERY_CEILING"
[ -f "$CEIL_FILE" ] || { echo "ERROR: no docs/INVENTED_QUERY_CEILING." >&2; exit 2; }
CEIL="$(grep -E '^[0-9]+$' "$CEIL_FILE" | head -1)"
case "$CEIL" in "" | *[!0-9]*) echo "ERROR: docs/INVENTED_QUERY_CEILING holds no integer." >&2; exit 2 ;; esac

python3 - "$REPO_ROOT" <<'PY'
import os, re, sys

root = sys.argv[1]
DECL = re.compile(r"^\s*var\s+(\w+)\s*:\s*(?:float|int|Vector2|Vector3|bool)\s*=\s*(.+?)\s*$")
# The receiver must be the substrate: `_field`, `_material`, `material`, `field`, or those through an actor.
GUARD = re.compile(r'\b(?:\w+\.)?(_?(?:field|material|weather|f))\.has_method\("(\w+)"\)')
EMPTY = {"0.0", "0", "false", "Vector2.ZERO", "Vector3.ZERO", "NAN", "-1", "-1.0", "INF"}

hits = []
for dp, dns, fns in os.walk(os.path.join(root, "addons", "local_agents")):
    dns[:] = [d for d in dns if d not in (".godot", "thirdparty")]
    for fn in sorted(fns):
        if not fn.endswith(".gd"):
            continue
        path = os.path.join(dp, fn)
        rel = os.path.relpath(path, root)
        try:
            lines = open(path, errors="replace").read().splitlines()
        except OSError:
            continue
        for i, line in enumerate(lines):
            g = GUARD.search(line)
            if not g:
                continue
            for back in (1, 2):
                if i - back < 0:
                    break
                d = DECL.match(lines[i - back])
                if not d:
                    continue
                var, val = d.group(1), d.group(2)
                body = lines[i + 1] if i + 1 < len(lines) else ""
                if re.search(r"\b%s\s*=" % re.escape(var), body) and val not in EMPTY:
                    hits.append((rel, i + 1, var, val, g.group(2)))
                break

print('INVENTED_FALLBACKS={"count":%d}' % len(hits))
for rel, n, var, val, meth in hits:
    print("  %s:%d  %s = %s   stands in when %s() is missing" % (rel, n, var, val, meth))

if hits:
    print("\nA measurement that could not be taken is ABSENT, not a number somebody picked. Either call the")
    print("method directly and let a missing one fault, or default to an empty value and refuse downstream.")
    sys.exit(1)
print("check_no_invented_fallback: scalars OK")
PY
rc=$?
[ "$rc" -eq 0 ] || exit "$rc"

# --- ARM TWO: a bool or int QUERY answering from a literal when the substrate is absent ----------------
out="$(python3 - "$REPO_ROOT" <<'PY'
import os, re, sys

root = sys.argv[1]
FUNC = re.compile(r"^(\s*)(?:static\s+)?func\s+(\w+)\s*\(.*?\)\s*->\s*(bool|int)\s*:\s*$")
# A QUESTION about the world, not an action reporting what it did.
QUERY = re.compile(r"^_?(?:is|has|can|are|was|any|all)_|_(?:at|count|cells|total|live|min|max)$")
# The absent collaborator must be the substrate, the scope the scalar arm above already uses.
RECV = r"(?:\w+\.)?_?(?:field|material|weather|queries|ecology|terrain|body|sun\w*|gpu|grid|seal|impacts|star|f)"
ABSENCE = re.compile(RECV + r"\s*(?:[!=]=\s*null|\.has_method\(|\.is_empty\(\)|\.size\(\)\s*==\s*0"
                     r"|\.length_squared\(\)\s*<)|is_zero_approx\(\s*" + RECV)
RET = re.compile(r"^\s*return\s+(true|false|-?\d+)\s*(?:#.*)?$")

hits = []
for base in ("sim", "creatures"):
    for dp, dns, fns in os.walk(os.path.join(root, "addons", "local_agents", base)):
        dns[:] = [d for d in dns if d not in (".godot", "thirdparty")]
        for fn in sorted(fns):
            if not fn.endswith(".gd"):
                continue
            path = os.path.join(dp, fn)
            rel = os.path.relpath(path, root)
            lines = open(path, errors="replace").read().splitlines()
            i = 0
            while i < len(lines):
                m = FUNC.match(lines[i])
                if not m:
                    i += 1
                    continue
                indent, name, typ = m.groups()
                j, body = i + 1, []
                while j < len(lines):
                    ln = lines[j]
                    if ln.strip() and not ln.startswith(indent + "\t"):
                        break
                    body.append((j, ln))
                    j += 1
                if QUERY.search(name) and ABSENCE.search("\n".join(b for _, b in body)):
                    for n, ln in body:
                        r = RET.match(ln)
                        if r:
                            hits.append("  %s:%d  %s() -> %s answers %s with the substrate absent"
                                        % (rel, n + 1, name, typ, r.group(1)))
                i = j

print('INVENTED_QUERIES={"count":%d}' % len(hits))
print("\n".join(hits))
PY
)"
prc=$?
[ "$prc" -eq 0 ] || { echo "check_no_invented_fallback: the query scan did not run." >&2; exit 2; }
n="$(printf '%s\n' "$out" | head -1 | sed -n 's/.*"count":\([0-9]*\).*/\1/p')"
case "$n" in "" | *[!0-9]*) echo "check_no_invented_fallback: the query scan produced no count." >&2; exit 2 ;; esac
printf '%s\n' "$out"
if [ "$n" -gt "$CEIL" ]; then
	echo "" >&2
	echo "check_no_invented_fallback: $n bool/int queries answer from a literal, ceiling $CEIL." >&2
	echo "  A bool has no NAN. If the reading cannot be taken the caller is told, never handed a value." >&2
	exit 1
fi
ceiling_slack "INVENTED_QUERY_CEILING" "$n" "$CEIL" 0 "$REPO_ROOT" || exit 1
echo "check_no_invented_fallback: OK ($n bool/int queries against a ceiling of $CEIL)"
