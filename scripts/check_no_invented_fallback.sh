#!/usr/bin/env bash
# =====================================================================================================
# NO INVENTED FALLBACK — a duck-typed probe may not stand in a number for a measurement it could not take.
#
# The shape:
#     var t: float = 15.0
#     if _field.has_method("temp_at"):
#         t = float(_field.temp_at(_base))
#
# If the method is ever renamed the branch goes quiet and the tornado believes the air is 15 °C. That is
# the same defect check_no_silent_fallback.sh catches in `.get(key, mirror)` form, wearing a duck-type
# instead of a dictionary — and it is worse, because the substitute is a literal nobody derived.
#
# Found here: three different invented temperatures for "I could not read the field" — 15.0 in Tornado,
# 20.0 in Hurricane, 20.0 in Fish — and the Hurricane one was compared against WARM_OCEAN_TEMP to decide
# whether a hurricane intensifies. Every guarded method existed, so every branch was unreachable: dead
# code holding a loaded gun.
#
# BANNED: a scalar initialised to a non-empty literal and then assigned inside a has_method() guard,
# WHERE THE RECEIVER IS THE SUBSTRATE. The field is one concrete class, so probing it is never
# polymorphism — the guard can only be a leftover, and its false branch is unreachable until it isn't.
# ALLOWED: an empty default (0.0 / false / ZERO / NAN), which reads as ABSENT rather than as a reading.
# ALSO ALLOWED, and the reason for the receiver scope: genuine dispatch over heterogeneous nodes, like
# CreatureThink asking a food node for `food_mass_per_unit` — a plant and a carcass really do differ, and
# the 1.0 there is a declared unit contract rather than a measurement somebody guessed.
#
# EXIT CODES. 0 none · 1 found · 2 could not run.
# =====================================================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 not on PATH — a gate that cannot run FAILS." >&2; exit 2; }
[ -d "$REPO_ROOT/addons/local_agents" ] || { echo "ERROR: source root missing." >&2; exit 2; }

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
print("check_no_invented_fallback: OK")
PY
