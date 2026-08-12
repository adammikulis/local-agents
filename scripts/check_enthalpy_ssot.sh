#!/usr/bin/env bash
# Phase-from-energy has one definition per side of the GPU boundary: kernels3d/enthalpy.glsli and
# LASubstances.enthalpy_to_state. This holds them equal on VALUES and on the FORMULA.
#
# Every value in the GLSL carries a trailing `// CONST_NAME` naming its authority in LAPhysical.
# Every boundary of the phase ladder must be built from the same expression on both sides: a gate that
# only checked the constants passed while the two sides put them in incompatible expressions.
#
# EXIT CODES. 0 pass · 1 the two sides diverged · 2 the gate could not run, never a silent pass.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
G="$ROOT/addons/local_agents/sim/material/kernels3d/enthalpy.glsli"
P="$ROOT/addons/local_agents/sim/material/PhysicalConstants.gd"
S="$ROOT/addons/local_agents/sim/material/Substances.gd"
[ -f "$G" ] || { echo "check_enthalpy_ssot: MISSING $G" >&2; exit 2; }
[ -f "$P" ] || { echo "check_enthalpy_ssot: MISSING $P" >&2; exit 2; }
[ -f "$S" ] || { echo "check_enthalpy_ssot: MISSING $S" >&2; exit 2; }

python3 - "$G" "$P" "$S" <<'PY'
import re, sys
glsl = open(sys.argv[1]).read()
gd = open(sys.argv[2]).read()
sub = open(sys.argv[3]).read()

# --- the authority ----------------------------------------------------------------------------------------
# A literal `const X: float = 4184.0` is comparable. A const whose value is an EXPRESSION is not, and a GLSL
# value claiming such a name is an unverifiable claim, so it fails rather than being skipped. The value must
# run to end of line (bar a comment): anchoring it is what stops `= ENTROPY_CASIO3_J_MOL_K \` from matching
# the leading `E` and killing the gate with a ValueError before it checked anything.
LITERAL = r'[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?'
auth, expr_only = {}, set()
for m in re.finditer(r'^const\s+([A-Z0-9_]+)\s*:\s*float\s*=\s*(.+?)\s*$', gd, re.M):
    name, rhs = m.group(1), re.sub(r'\s*#.*$', '', m.group(2)).strip()
    if re.fullmatch(LITERAL, rhs):
        auth[name] = float(rhs)
    else:
        expr_only.add(name)
if not auth:
    print("check_enthalpy_ssot: no literal float constants found in PhysicalConstants.gd — the authority "
          "could not be read.", file=sys.stderr)
    sys.exit(2)

# --- the values -------------------------------------------------------------------------------------------
pairs = re.findall(r'(' + LITERAL + r')\s*[;,]?\s*//\s*(?:LAPhysical\.)?([A-Z0-9_]+)\s*$', glsl, re.M)
if not pairs:
    print("check_enthalpy_ssot: no `value // CONST_NAME` pairs found — the GLSL lost its bindings.",
          file=sys.stderr)
    sys.exit(1)

bad = []
for val, name in pairs:
    if name in expr_only:
        bad.append((name, val, "authority is an EXPRESSION, not comparable"))
    elif name not in auth:
        bad.append((name, val, "NOT IN LAPhysical"))
    elif abs(float(val) - auth[name]) > abs(auth[name]) * 1e-9:
        bad.append((name, val, repr(auth[name])))
if bad:
    print("check_enthalpy_ssot: FAILED — enthalpy.glsli diverged from LAPhysical:", file=sys.stderr)
    for name, got, want in bad:
        print("  %-36s glsl=%-14s authority=%s" % (name, got, want), file=sys.stderr)
    sys.exit(1)

# --- the formula ------------------------------------------------------------------------------------------
# The four boundaries of the ladder, in the order the enthalpy of a warming cell crosses them. Both sides
# must build each one from the SAME expression, not merely mention it in the same order: dropping `+ l_fus`
# leaves the fusion plateau with zero width, and an order check cannot see that.
STEPS = ["h_melt_start", "h_melt_end", "h_boil_start", "h_boil_end"]

# One canonical spelling per quantity, so the two languages' syntax does not count as a difference.
ALIAS = [(r'\bs\.', ''), (r'\bPC\.', ''), (r'\bLA_KELVIN_OFFSET\b', 'KELVIN_OFFSET'),
         (r'\bmelt\b', 'melt_c'), (r'\bfloat\b', ''), (r'\bvar\b', '')]


def body(txt, opener):
    """The text of one function, from its signature to the first line that is flush-left again."""
    i = txt.find(opener)
    if i < 0:
        return ""
    out = []
    for line in txt[i:].split("\n")[1:]:
        if line and not line[0].isspace() and not line.startswith(("}", ")")):
            break
        out.append(line)
    return "\n".join(out)


def boundaries(txt, label):
    """Each STEP mapped to its canonical right-hand side, in the order the file assigns them."""
    got, order = {}, []
    for line in txt.split("\n"):
        code = re.sub(r'(//|#).*$', '', line).strip()
        m = re.match(r'^(?:var\s+|float\s+)?(' + "|".join(STEPS) + r')\s*(?::\s*float\s*)?=\s*(.+?);?$', code)
        if not m or m.group(1) in got:
            continue
        rhs = m.group(2)
        for pat, rep in ALIAS:
            rhs = re.sub(pat, rep, rhs)
        got[m.group(1)] = re.sub(r'\s+', '', rhs)
        order.append(m.group(1))
    if order != STEPS:
        print("check_enthalpy_ssot: FAILED — %s does not assign the four ladder boundaries in order."
              % label, file=sys.stderr)
        print("  found:    %s" % order, file=sys.stderr)
        print("  expected: %s" % STEPS, file=sys.stderr)
        sys.exit(1)
    return got


g_body = body(glsl, "vec4 la_enthalpy_to_state(")
d_body = body(sub, "static func enthalpy_to_state(")
if not g_body or not d_body:
    print("check_enthalpy_ssot: could not find la_enthalpy_to_state / enthalpy_to_state — the gate has no "
          "subject.", file=sys.stderr)
    sys.exit(2)

gb = boundaries(g_body, "enthalpy.glsli")
db = boundaries(d_body, "Substances.gd")
diff = [(k, gb[k], db[k]) for k in STEPS if gb[k] != db[k]]
if diff:
    print("check_enthalpy_ssot: FAILED — the two definitions build the ladder from different expressions:",
          file=sys.stderr)
    for k, g, d in diff:
        print("  %-14s glsl= %s" % (k, g), file=sys.stderr)
        print("  %-14s gd:   %s" % ("", d), file=sys.stderr)
    sys.exit(1)

print("Enthalpy SSOT gate passed (%d constants bound to LAPhysical, %d ladder boundaries identical)."
      % (len(pairs), len(STEPS)))
PY
