#!/usr/bin/env bash
# ONE STACKING, TWO LANGUAGES. kernels3d/stack.glsli reconstructs a stratified cell's face pressure and
# LAFieldLithostaticSeed::stack_drop seeds against it; a seed marching a different stack than the stepper
# holds is a world that starts out of balance. Compares the two bodies as token streams, so a rename or a
# reordered term fails and only the language's own spelling is allowed to differ.
# EXIT 0 the two agree * 1 they have drifted * 2 could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh"
require_tool python3

GLSL="$ROOT/addons/local_agents/sim/material/kernels3d/stack.glsli"
CPP="$ROOT/addons/local_agents/gdextensions/localagents/src/LAFieldLithostaticSeed.cpp"
for f in "$GLSL" "$CPP"; do
	[ -f "$f" ] || { echo "check_stack_ssot: MISSING ${f#"$ROOT"/}" >&2; exit 2; }
done

python3 - "$GLSL" "$CPP" <<'PY'
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

g = body(sys.argv[1], "float la_stack_drop(")
c = body(sys.argv[2], "double stack_drop(")
if g is None or c is None:
    print("check_stack_ssot: one of the two stack functions is absent, so nothing was compared.",
          file=sys.stderr)
    sys.exit(2)
gt, ct = tokens(g), tokens(c)
if gt == ct:
    print("check_stack_ssot: OK (%d tokens, the same on both sides)" % len(gt))
    sys.exit(0)
print("check_stack_ssot: the kernel's stacking and its CPU twin have drifted.", file=sys.stderr)
for k in range(min(len(gt), len(ct))):
    if gt[k] != ct[k]:
        print("  first difference at token %d: glsl %r against cpp %r" % (k, gt[k], ct[k]), file=sys.stderr)
        break
else:
    print("  one body is %d tokens and the other %d." % (len(gt), len(ct)), file=sys.stderr)
sys.exit(1)
PY
