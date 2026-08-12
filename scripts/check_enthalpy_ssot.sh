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
GM="$ROOT/addons/local_agents/sim/material/kernels3d/mixture_enthalpy.glsli"
SM="$ROOT/addons/local_agents/sim/material/MixtureEnthalpy.gd"
for f in "$G" "$P" "$S" "$GM" "$SM"; do
  [ -f "$f" ] || { echo "check_enthalpy_ssot: MISSING $f" >&2; exit 2; }
done

python3 - "$G" "$P" "$S" "$GM" "$SM" <<'PY'
import re, sys
glsl = open(sys.argv[1]).read()
gd = open(sys.argv[2]).read()
sub = open(sys.argv[3]).read()
glsl_mix = open(sys.argv[4]).read()
sub_mix = open(sys.argv[5]).read()

# --- the authority ----------------------------------------------------------------------------------------
# A literal `const X: float = 4184.0` is comparable. A const whose value is an EXPRESSION is not, and a GLSL
# value claiming such a name is an unverifiable claim, so it fails rather than being skipped. The value must
# run to end of line (bar a comment): anchoring it is what stops `= ENTROPY_CASIO3_J_MOL_K \` from matching
# the leading `E` and killing the gate with a ValueError before it checked anything.
LITERAL = r'[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?'
auth, expr_only = {}, set()
# Both authority files: LAPhysical carries what is not a property of a substance, LASubstances the rest.
for src in (gd, sub):
    for m in re.finditer(r'^const\s+([A-Z0-9_]+)\s*:\s*(?:float|int)\s*=\s*(.+?)\s*$', src, re.M):
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
pairs = re.findall(r'(' + LITERAL + r')\s*[;,)]?\s*//\s*(?:LAPhysical\.|LASubstances\.)?([A-Z0-9_]+)\s*$',
                   glsl, re.M)
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

# BELOW THE TRIPLE POINT the ladder has a different pair of rungs, and they live outside the four above, so
# the boundary check could not see either side losing them.
SUB_STEPS = ["h_sub_start", "h_sub_end"]

# A rung the expression check cannot reach, because deleting it deletes the expression too. Each entry is
# (what it models, the GLSL symbol, the GDScript symbol, where it must be REACHABLE from). "ladder" means it
# must appear inside the phase-from-energy function itself, not merely be defined somewhere in the file.
RUNGS = [
    ("no liquid below the triple point", "la_sublimes_at",         "sublimes_at",             "ladder"),
    ("the frost point",                  "la_sublimation_c_at",    "sublimation_c_at",        "ladder"),
    ("the sublimation latent heat",      "la_latent_sublimation",  "latent_sublimation_j_kg", "ladder"),
    ("the melting INTERVAL",             "la_liquidus_c_at",       "liquidus_c_at",           "ladder"),
    ("the gas tail",                     "la_gas_state",           "_gas_state",              "ladder"),
    ("dissociation",                     "la_dissociated_fraction", "dissociated_fraction",   "file"),
    ("ionisation",                       "la_ionised_fraction",    "ionised_fraction",        "file"),
]

MIX_RUNGS = [
    ("the saturation split",   "la_mix_vapour_fraction", "vapour_fraction"),
    ("the boundary walk",      "la_mix_breakpoints",     "breakpoints"),
    ("the latent-heat jump",   "la_mix_jump_at",         "jump_at"),
    ("the bracketed solve",    "la_mix_solve",           "_solve"),
    ("the cell's temperature", "la_mix_state",           "state"),
]

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


def boundaries(txt, label, steps):
    """Each step mapped to its canonical right-hand side, in the order the file assigns them."""
    got, order = {}, []
    for line in txt.split("\n"):
        code = re.sub(r'(//|#).*$', '', line).strip()
        m = re.match(r'^(?:var\s+|float\s+)?(' + "|".join(steps) + r')\s*(?::\s*float\s*)?=\s*(.+?);?$', code)
        if not m or m.group(1) in got:
            continue
        rhs = m.group(2)
        for pat, rep in ALIAS:
            rhs = re.sub(pat, rep, rhs)
        got[m.group(1)] = re.sub(r'\s+', '', rhs)
        order.append(m.group(1))
    if order != steps:
        print("check_enthalpy_ssot: FAILED — %s does not assign %s in order."
              % (label, steps), file=sys.stderr)
        print("  found:    %s" % order, file=sys.stderr)
        sys.exit(1)
    return got


g_body = body(glsl, "vec4 la_enthalpy_to_state(")
d_body = body(sub, "static func enthalpy_to_state(")
if not g_body or not d_body:
    print("check_enthalpy_ssot: could not find la_enthalpy_to_state / enthalpy_to_state — the gate has no "
          "subject.", file=sys.stderr)
    sys.exit(2)

for steps in (STEPS, SUB_STEPS):
    gb = boundaries(g_body, "enthalpy.glsli", steps)
    db = boundaries(d_body, "Substances.gd", steps)
    diff = [(k, gb[k], db[k]) for k in steps if gb[k] != db[k]]
    if diff:
        print("check_enthalpy_ssot: FAILED — the two definitions build the ladder from different "
              "expressions:", file=sys.stderr)
        for k, g, d in diff:
            print("  %-14s glsl= %s" % (k, g), file=sys.stderr)
            print("  %-14s gd:   %s" % ("", d), file=sys.stderr)
        sys.exit(1)

# --- the rungs --------------------------------------------------------------------------------------------
# A branch deleted from one side takes its expression with it, so the comparison above goes quiet rather than
# red. Name each rung and require it on BOTH sides — defined, and reached from the function that matters.
DEF_RE = {"glsl": re.compile(r'^(?:[A-Za-z_][A-Za-z0-9_]*(?:\[[^\]]*\])?\s+)+([a-z_][A-Za-z0-9_]*)\s*\(',
                             re.M),
          "gd": re.compile(r'^(?:static\s+)?func\s+([A-Za-z_]\w*)\s*\(', re.M)}


def bodies_of(txt, kind):
    """Every function in the file, name -> body text."""
    out = {}
    for m in DEF_RE[kind].finditer(txt):
        lines = []
        for line in txt[m.start():].split("\n")[1:]:
            if line and not line[0].isspace() and not line.startswith(("}", ")")):
                break
            lines.append(line)
        out[m.group(1)] = "\n".join(lines)
    return out


def reachable(root, funcs):
    """Names called from `root`, following calls into this file's own functions."""
    seen, queue = set(), [root]
    while queue:
        name = queue.pop()
        for called in re.findall(r'\b([A-Za-z_]\w*)\s*\(', funcs.get(name, "")):
            if called in seen:
                continue
            seen.add(called)
            if called in funcs:
                queue.append(called)
    return seen


g_funcs, d_funcs = bodies_of(glsl, "glsl"), bodies_of(sub, "gd")
gm_funcs, sm_funcs = bodies_of(glsl_mix, "glsl"), bodies_of(sub_mix, "gd")
if "la_mix_state" not in gm_funcs or "state" not in sm_funcs:
    print("check_enthalpy_ssot: could not find la_mix_state / LAMixtureEnthalpy.state — the mixture "
          "inverter has no subject.", file=sys.stderr)
    sys.exit(2)
g_reach = reachable("la_enthalpy_to_state", g_funcs)
d_reach = reachable("enthalpy_to_state", d_funcs)
gm_reach = reachable("la_mix_state", gm_funcs)
sm_reach = reachable("state", sm_funcs)

missing = []
for label, gsym, dsym, where in RUNGS:
    for sym, funcs, reach, fname in ((gsym, g_funcs, g_reach, "enthalpy.glsli"),
                                     (dsym, d_funcs, d_reach, "Substances.gd")):
        if sym not in funcs:
            missing.append((label, fname, "%s is not defined" % sym))
        elif where == "ladder" and sym not in reach:
            missing.append((label, fname, "%s never reached from the phase ladder" % sym))
for label, gsym, dsym in MIX_RUNGS:
    for sym, funcs, reach, fname in ((gsym, gm_funcs, gm_reach, "mixture_enthalpy.glsli"),
                                     (dsym, sm_funcs, sm_reach, "MixtureEnthalpy.gd")):
        if sym not in funcs:
            missing.append((label, fname, "%s is not defined" % sym))
        elif sym not in reach and sym not in ("la_mix_state", "state"):
            missing.append((label, fname, "%s never reached from the mixture inverter" % sym))

if missing:
    print("check_enthalpy_ssot: FAILED — a rung of the phase curve is missing:", file=sys.stderr)
    for label, fname, why in missing:
        print("  %-34s %-24s %s" % (label, fname, why), file=sys.stderr)
    sys.exit(1)

print("Enthalpy SSOT gate passed (%d constants bound, %d ladder boundaries identical, %d rungs present "
      "on both sides)." % (len(pairs), len(STEPS) + len(SUB_STEPS), len(RUNGS) + len(MIX_RUNGS)))
PY
