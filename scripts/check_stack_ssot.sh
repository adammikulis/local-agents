#!/usr/bin/env bash
# ONE RECONSTRUCTION, TWO LANGUAGES. kernels3d/stack.glsli reconstructs a stratified cell's face pressure
# and kernels3d/eos.glsli states its pressure from its own matter; a seed holding a different stack or a
# different equation of state than the stepper is a world that starts out of balance. Compared as token
# streams, so a rename or a reordered term fails and only the language's own spelling may differ.
# EXIT 0 the two agree * 1 they have drifted * 2 could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh"
require_tool python3

GLSL="$ROOT/addons/local_agents/sim/material/kernels3d/stack.glsli"
EOS="$ROOT/addons/local_agents/sim/material/kernels3d/eos.glsli"
CPP="$ROOT/addons/local_agents/gdextensions/localagents/src/LAFieldLithostaticSeed.cpp"
for f in "$GLSL" "$EOS" "$CPP"; do
	[ -f "$f" ] || { echo "check_stack_ssot: MISSING ${f#"$ROOT"/}" >&2; exit 2; }
done

python3 - "$GLSL" "$EOS" "$CPP" <<'PY'
import re, sys

def body(path, sig):
    src = open(path, encoding="utf-8").read()
    i = src.find(sig)
    if i < 0:
        return None
    i = src.index("{", i)
    depth, j = 0, i
    while j < len(src):
        if src[j] == "{":
            depth += 1
        elif src[j] == "}":
            depth -= 1
            if depth == 0:
                return src[i + 1:j]
        j += 1
    return None

# The two spellings of the same arithmetic: types and the min/max case are the language's, not the model's.
SAME = {"float": "num", "double": "num", "MAX": "max", "MIN": "min", "CLAMP": "clamp"}

def tokens(text):
    out = []
    for t in re.findall(r"[A-Za-z_][A-Za-z_0-9]*|[0-9]+\.?[0-9]*|[^\sA-Za-z_0-9]", text):
        out.append(SAME.get(t, t))
    return out

PAIRS = [
    ("stacking", sys.argv[1], "float la_stack_p(", "double stack_p("),
    ("equation of state", sys.argv[2], "float la_eos_p(", "double eos_p("),
]
total = 0
for what, path, gsig, csig in PAIRS:
    g = body(path, gsig)
    c = body(sys.argv[3], csig)
    if g is None or c is None:
        print("check_stack_ssot: the %s is absent on one side, so nothing was compared." % what,
              file=sys.stderr)
        sys.exit(2)
    gt, ct = tokens(g), tokens(c)
    if gt == ct:
        total += len(gt)
        continue
    print("check_stack_ssot: the kernel's %s and its CPU twin have drifted." % what, file=sys.stderr)
    for k in range(min(len(gt), len(ct))):
        if gt[k] != ct[k]:
            print("  first difference at token %d: glsl %r against cpp %r" % (k, gt[k], ct[k]),
                  file=sys.stderr)
            break
    else:
        print("  one body is %d tokens and the other %d." % (len(gt), len(ct)), file=sys.stderr)
    sys.exit(1)
print("check_stack_ssot: OK (%d tokens over %d pairs, the same on both sides)" % (total, len(PAIRS)))
sys.exit(0)
PY
