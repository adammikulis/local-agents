#!/usr/bin/env bash
# =====================================================================================================
# PHYSICAL CONSTANTS GATE — the GLSL copies must equal the one authority.
#
# WHY THIS EXISTS. Water froze at 12.5 °C in this simulation. The planet could not get below ~11 °C, so
# instead of fixing the planet someone moved the freezing point of WATER up to meet it — and because GLSL
# cannot read GDScript, the moved value had to be copied by hand into every kernel that needed it. It
# ended up in FIVE places at THREE different values: 12.5 in MaterialReactions3D.gd and
# snowice_sphere3d.glsl, 13.0 in charge_accum_sphere3d.glsl and the since-deleted activity_sphere3d.glsl,
# melting at 14.0.
# Snow then "worked", and every measurement ever taken against those numbers was meaningless.
#
# The real values now live in ONE authority: addons/local_agents/sim/material/PhysicalConstants.gd
# (class LAPhysical). The kernels STILL declare their own copies, because a compute shader has no way to
# import a GDScript constant. That copy is where the drift comes back. This gate is the substitute for
# the import the language does not have.
#
# ----------------------------------------------------------------------------------------------------
# THE RULE, in three parts.
#
# 1. AN EXPLICIT REFERENCE IS A BINDING CONTRACT.
#    A kernel constant whose trailing comment names `LAPhysical.<NAME>` must equal that constant's value:
#        const float FREEZE_TEMP = 0.0;   // LAPhysical.WATER_FREEZE_C — the phase boundary, not a tunable
#    An explicit reference always WINS over the name heuristic in part 2, which is how
#    `const float FREEZE_T = -10.0;  // LAPhysical.CHARGE_ZONE_WARM_C` is correctly read as the warm edge
#    of the mixed-phase charging band and not as the freezing point of water. If you mean a quantity, say
#    which one; the comment is the declaration.
#
#    A SPAN may be written relative to another endpoint. When the words "down to" (or "span to") precede
#    the reference, the constant is a WIDTH: it must equal the distance from the nearest preceding
#    directly-referenced constant in the same file to the named one. That is how
#        const float FREEZE_T  = -10.0;  // LAPhysical.CHARGE_ZONE_WARM_C
#        const float COLD_SPAN =  15.0;  // down to LAPhysical.CHARGE_ZONE_COLD_C (-25 C)
#    is checked as |-10 - (-25)| == 15. If the reference is followed by a parenthesised number, that
#    number is checked too, so the comment itself cannot go stale while the code stays right.
#
# 2. A WATCHED NAME IS BOUND EVEN WITHOUT A COMMENT — so a fitted constant cannot be added silently.
#    Some names ARE the physical quantity. A kernel constant whose NAME says it is a water phase point
#    (contains FREEZE / MELT / THAW / BOIL) or the charge-separation band (CHARGE + FREEZE/ZONE/WARM/COLD)
#    must be bound to the authority in ONE of two ways:
#        (a) explicitly, by an `LAPhysical.<NAME>` comment (part 1), or
#        (b) implicitly, by simply HAVING the authority's value.
#    Anything else fails. A fitted constant fails by construction: fitting means moving the value off the
#    physical one, so it can satisfy neither (a) nor (b). A correct-but-undocumented constant passes and
#    prints a NOTE asking for the comment. The charge band has two endpoints and no safe default, so it
#    requires (a) — an unannotated CHARGE_* temperature always fails.
#
# 3. GENUINE MODEL PARAMETERS ARE NOT TOUCHED, deliberately.
#    Rates, gains, fractions, thresholds, minima, capacities and numerical guards are properties of the
#    MODEL, not of matter, and they belong next to the code that uses them. So the name heuristic ignores
#    any name carrying a model token (RATE, FRAC, GAIN, SCALE, COEFF, MIN, MAX, THRESH, STEP, COUNT, DAMP,
#    LEAK, SPAN, MASS, FLOW, DEPTH) — BOIL_RATE and BOIL_MAX_FRAC are model parameters, BOIL_TEMP is not —
#    and any name qualified by another material (ROCK, BASALT, LAVA, MAGMA, IRON, METAL, SOLIDIF), whose
#    phase points are not water's.
#
# SCOPE, v2: the water phase points, the charge-separation band, and the two radiation constants.
# Widening it is a one-line edit to WATCHED_* below.
#
# *(Corrected 2026-08-07. This paragraph used to name two quantities as "deliberately NOT watched yet
# because the kernels and the authority genuinely disagree today", citing
# `heat3d_solar_sphere3d.glsl:96  SOLAR_CONSTANT = 600.0` and `:95  STEFAN = 5.670374e-8`, and ended "Add
# them here the day the kernel is reconciled." THE KERNEL WAS RECONCILED. heat3d_solar_sphere3d.glsl:114-115
# now carry 5.670374419e-8 and 1361.0, both already annotated, so rule 1 has been binding them the whole
# time — the comment outlived the disagreement and went on telling every reader this planet's sun was dimmed
# to 600 W/m². They join the watched set below, which is what that sentence asked for: a NEW kernel constant
# named SOLAR_CONSTANT or STEFAN can no longer be introduced without a reference.)*
#
# EXIT CODES.  0 = clean.  1 = a violation.  2 = the gate COULD NOT RUN (missing tool, missing authority
# file, missing kernel directory, or an authority that parsed to zero constants). 2 is distinct on
# purpose: this repo has already shipped gates that reported a pass while examining zero files, because a
# missing `rg` on the CI runner made the check vacuous. A gate that cannot run must fail, never pass.
# =====================================================================================================
set -euo pipefail

# Pure-bash, no `dirname`: this must still resolve when PATH is broken, or the missing-tool check below
# never gets a chance to report exit 2.
SCRIPT_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
# shellcheck source=lib_require.sh
source "$SCRIPT_DIR/lib_require.sh"
require_tool awk   # every comparison below is an awk numeric compare; without it the gate is vacuous
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

AUTHORITY="${LA_PHYSICAL_AUTHORITY:-$REPO_ROOT/addons/local_agents/sim/material/PhysicalConstants.gd}"
KERNEL_DIR="${LA_KERNEL_DIR:-$REPO_ROOT/addons/local_agents/sim/material/kernels3d}"

if [[ ! -f "$AUTHORITY" ]]; then
  echo "ERROR: check_physical_constants.sh cannot find the authority file:" >&2
  echo "       $AUTHORITY" >&2
  echo "       Physical constants live in ONE place. Without it every kernel copy is unverifiable," >&2
  echo "       so this is a hard failure, not a skip." >&2
  exit 2
fi
if [[ ! -d "$KERNEL_DIR" ]]; then
  echo "ERROR: check_physical_constants.sh cannot find the kernel directory:" >&2
  echo "       $KERNEL_DIR" >&2
  exit 2
fi

# .glsli TOO, NOT JUST .glsl. Shared includes hold real constants — rc_shared.glsli owns the five RC_*
# volumetric heat capacities for every kernel that includes it — and a glob of `*.glsl` alone would let a
# value slip out of this gate simply by being factored into a header. Added 2026-08-09 with that file.
shopt -s nullglob
kernels=("$KERNEL_DIR"/*.glsl "$KERNEL_DIR"/*.glsli)
shopt -u nullglob
if [[ ${#kernels[@]} -eq 0 ]]; then
  echo "ERROR: no .glsl/.glsli kernels found under $KERNEL_DIR — refusing to report a pass on zero files." >&2
  exit 2
fi

# --- 1. parse the authority into NAME<TAB>VALUE ------------------------------------------------------
AUTH_MAP="$(mktemp -t la_physical_auth.XXXXXX)"
trap 'rm -f "$AUTH_MAP"' EXIT
# DERIVED CONSTANTS ARE FIRST-CLASS HERE, and they have to be. A constant defined as an expression over
# other constants is how a RELATIONSHIP between measured quantities is made structural instead of asserted —
# LATENT_HEAT_SUBLIMATION_J_KG = LATENT_HEAT_VAPORISATION_0C_J_KG + LATENT_HEAT_FUSION_J_KG is Hess's law,
# and stating it as a literal is what let that law be broken by 2.433e5 J/kg in shipped code. But this parser
# accepted ONLY plain numeric literals, so deriving a constant silently dropped it from the authority map and
# every kernel copy of it became unbindable. That is the gate quietly getting weaker as the code gets better,
# which is the worst possible direction. So: literals first, then resolve expressions over already-known
# names, iterating until nothing new resolves. Supports the forms that actually occur — a chain of `+`, `-`,
# `*` and `/` over names and numbers, no parentheses, evaluated left to right. Anything it cannot resolve is
# simply absent from the map, exactly as before, and a kernel referencing it fails loudly rather than passing.
#
# LINE CONTINUATIONS ARE JOINED FIRST, and that is not cosmetic. This awk reads a line at a time, so a
# constant declared as `const NAME: float = \` with its expression on the following lines parsed as an empty
# value and fell out of the map entirely. That silently hid MOLAR_MASS_DRY_AIR_KG_MOL — a weighted mean over
# four mole fractions, written across five lines — and with it DRY_AIR_GAS_CONSTANT_J_KGK, which depends on
# it. THE SPECIFIC GAS CONSTANT OF DRY AIR, the most important structural parameter of an atmosphere, was
# invisible to the gate on the day it was added. Found 2026-08-10 when a new derived constant that depends on
# it could not be bound. Same failure mode the paragraph above describes, one syntax later: the gate got
# quietly weaker as the authority got better.
awk '
  # ONE VALUE PER TOKEN — a name or a numeric literal, exponent included.
  function val_of(tok,   v) {
    if (tok ~ /^[-+]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][-+]?[0-9]+)?$/) return tok + 0
    if (tok in known) return known[tok]
    return "UNRESOLVED"
  }
  # A `*` and `/` chain, evaluated left to right. Same precedence, so left-to-right IS correct here.
  function resolve_term(term,   n, parts, ops, i, acc, v, e) {
    e = term; ops = ""
    while (match(e, /[*\/]/)) { ops = ops substr(e, RSTART, 1); e = substr(e, RSTART + 1) }
    n = split(term, parts, /[*\/]/)
    for (i = 1; i <= n; i++) {
      v = val_of(parts[i])
      if (v == "UNRESOLVED") return "UNRESOLVED"
      if (i == 1) { acc = v; continue }
      if (substr(ops, i - 1, 1) == "*") acc = acc * v
      else { if (v == 0) return "UNRESOLVED"; acc = acc / v }
    }
    return acc
  }
  # PRECEDENCE IS REAL: split on + and - FIRST, then evaluate each */ term, then sum.
  #
  # *(Rewritten 2026-08-10. The previous resolver evaluated the WHOLE chain left to right with no
  # precedence, so `x1*M1 + x2*M2 + x3*M3 + x4*M4` — a weighted mean, the shape every derived mixture
  # property has — came out as ((((x1*M1)+x2)*M2)+x3)*M3... It did not fail; it produced a NUMBER. The
  # authority map then held 4.787e-5 for MOLAR_MASS_DRY_AIR_KG_MOL against a true 0.028968, and any kernel
  # bound to it would have been compared against garbage: a correct kernel constant FAILS and a wrong one can
  # PASS. That is strictly worse than the constant being absent, which is what the line-continuation bug
  # above was doing to the same constant. Exponent signs are protected before the +/- split, because
  # `1.0e-9` would otherwise be torn into `1.0e` and `9`.)*
  function resolve(expr,   n, i, parts, ops, acc, v, e, t) {
    gsub(/[ \t]/, "", expr)
    gsub(/[eE]\+/, "\001", expr); gsub(/[eE]-/, "\002", expr)
    e = expr; ops = ""
    while (match(e, /[-+]/)) { ops = ops substr(e, RSTART, 1); e = substr(e, RSTART + 1) }
    n = split(expr, parts, /[-+]/)
    for (i = 1; i <= n; i++) {
      t = parts[i]
      gsub(/\001/, "e+", t); gsub(/\002/, "e-", t)
      v = resolve_term(t)
      if (v == "UNRESOLVED") return "UNRESOLVED"
      if (i == 1) { acc = v; continue }
      if (substr(ops, i - 1, 1) == "+") acc = acc + v
      else acc = acc - v
    }
    return acc
  }
  match($0, /^[ \t]*const[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]*:[ \t]*float[ \t]*=/) {
    decl = substr($0, RSTART, RLENGTH)
    sub(/^[ \t]*const[ \t]+/, "", decl); sub(/[ \t]*:.*$/, "", decl)
    val = substr($0, RSTART + RLENGTH)
    sub(/#.*$/, "", val); gsub(/^[ \t]+|[ \t]+$/, "", val)
    if (val ~ /^[-+]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][-+]?[0-9]+)?$/) { known[decl] = val + 0; order[++nord] = decl; lit[decl] = val }
    else if (val != "") { pending[decl] = val; porder[++npend] = decl }
  }
  END {
    # iterate: an expression may name a constant that is itself an expression
    changed = 1
    while (changed) {
      changed = 0
      for (i = 1; i <= npend; i++) {
        d = porder[i]
        if (d in known) continue
        r = resolve(pending[d])
        if (r != "UNRESOLVED") { known[d] = r + 0; order[++nord] = d; lit[d] = sprintf("%.10g", r); changed = 1 }
      }
    }
    for (i = 1; i <= nord; i++) printf "%s\t%s\n", order[i], lit[order[i]]
  }
' <(sed -e :a -e '/\\$/N; s/\\\n//; ta' "$AUTHORITY") > "$AUTH_MAP"

# A CONSTANT THE PARSER CANNOT RESOLVE MUST NOT VANISH SILENTLY. The expression grammar has no parentheses,
# so `A * (B / C)` dropped CO2_UNIT_DENSITY_KG_M3 out of the map and every kernel copy of it became
# unbindable — reported as "the authority does not define it", which is false and sends the reader hunting
# for a typo. Third instance of this shape; the header above records the first two.
unresolved="$(sed -e :a -e '/\\$/N; s/\\\n//; ta' "$AUTHORITY" \
  | grep -E '^const [A-Z][A-Z0-9_]*: *float *=' \
  | sed -E 's/#.*$//' \
  | grep -F '(' | sed -E 's/^const ([A-Z0-9_]+).*/\1/' || true)"
if [ -n "$unresolved" ]; then
  echo "check_physical_constants: FAILED — the authority declares a constant the expression parser cannot read" >&2
  echo "$unresolved" | sed 's/^/  /' >&2
  echo "  The grammar is a flat chain of + - * / over names and numbers, with NO parentheses. Rewrite the" >&2
  echo "  declaration flat, or teach the parser. A constant it cannot read is absent from the authority map," >&2
  echo "  and every kernel that binds to it then fails with a misleading message." >&2
  exit 1
fi

auth_count="$(wc -l < "$AUTH_MAP" | tr -d ' ')"
if [[ "$auth_count" -eq 0 ]]; then
  echo "ERROR: parsed ZERO constants out of the authority file $AUTHORITY." >&2
  echo "       Either its syntax changed or the file is empty. Either way the gate cannot verify" >&2
  echo "       anything, so it fails rather than passing on an empty comparison." >&2
  exit 2
fi

# --- 2. check every kernel copy against it -----------------------------------------------------------
set +e
awk -v AUTH="$AUTH_MAP" -v ROOT="$REPO_ROOT/" '
  # ROOT is stripped literally, never as a regex — a repo path may contain regex metacharacters.
  function rel(p) { return (index(p, ROOT) == 1) ? substr(p, length(ROOT) + 1) : p }
  function num_eq(a, b,   d, m) { d = a - b; if (d < 0) d = -d; m = (b < 0 ? -b : b); return d <= 1e-9 * (m > 1 ? m : 1) }
  function fail(f, ln, msg) { printf "FAIL %s:%d  %s\n", rel(f), ln, msg; errors++ }

  BEGIN {
    while ((getline line < AUTH) > 0) { split(line, kv, "\t"); auth[kv[1]] = kv[2] + 0; authstr[kv[1]] = kv[2]; have[kv[1]] = 1 }
    close(AUTH)
    # v2 watched quantities. Widen here, not in the parser.
    WATCH_PHASE  = "(FREEZE|MELT|THAW|BOIL)"
    WATCH_CHARGE = "(FREEZE|ZONE|WARM|COLD)"
    # RADIATION. Each maps to exactly one authority constant, so an unannotated copy can be named outright
    # rather than asked about. These were the two the v1 scope left out while the kernel disagreed with the
    # authority; it no longer does.
    WATCH_RADIATION = "(SOLAR_CONSTANT|STEFAN)"
    MODEL_TOKENS = "(RATE|FRAC|GAIN|SCALE|COEFF|COEF|MIN|MAX|THRESH|STEP|COUNT|DAMP|LEAK|SPAN|MASS|FLOW|DEPTH)"
    OTHER_MATTER = "(ROCK|BASALT|LAVA|MAGMA|IRON|METAL|SOLIDIF)"
  }

  FNR == 1 { anchor_val = ""; anchor_name = ""; files++ }

  {
    line = $0
    ci = index(line, "//")
    decl = (ci ? substr(line, 1, ci - 1) : line)
    cmt  = (ci ? substr(line, ci + 2)   : "")
    if (decl !~ /^[ \t]*const[ \t]/) next
    if (!match(decl, /const[ \t]+(float|int|uint)[ \t]+[A-Za-z_][A-Za-z0-9_]*/)) next
    seg = substr(decl, RSTART, RLENGTH); nf = split(seg, parts, /[ \t]+/); name = parts[nf]
    eq = index(decl, "="); if (!eq) next
    val = substr(decl, eq + 1); sub(/;.*$/, "", val); gsub(/^[ \t]+|[ \t]+$/, "", val)
    literal = (val ~ /^[-+]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][-+]?[0-9]+)?[fF]?$/)
    v = val + 0
    checked++

    # --- explicit reference: the binding contract -----------------------------------------------
    if (match(cmt, /LAPhysical\.[A-Za-z0-9_]+/)) {
      ref = substr(cmt, RSTART + 11, RLENGTH - 11)
      pre = substr(cmt, 1, RSTART - 1)
      post = substr(cmt, RSTART + RLENGTH)
      if (!have[ref]) {
        fail(FILENAME, FNR, name " references LAPhysical." ref ", which the authority does not define. Typo, or the constant was renamed/removed there.")
        next
      }
      if (!literal) {
        fail(FILENAME, FNR, name " references LAPhysical." ref " but its value \"" val "\" is not a plain numeric literal, so the gate cannot verify it. Write the number.")
        next
      }
      # a parenthesised restatement right after the reference must also be right
      if (match(post, /^[ \t]*\([-+]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][-+]?[0-9]+)?/)) {
        q = substr(post, RSTART, RLENGTH); sub(/^[ \t]*\(/, "", q)
        if (!num_eq(q + 0, auth[ref]))
          fail(FILENAME, FNR, name "'\''s comment restates LAPhysical." ref " as " q ", but the authority says " authstr[ref] ". The comment is stale.")
      }
      if (pre ~ /(down to|down-to|spans? to|span from|span down to)[ \t]*$/) {
        if (anchor_val == "") {
          fail(FILENAME, FNR, name " is written as a span down to LAPhysical." ref ", but no directly-referenced constant precedes it in this file to span FROM. Give the endpoint an LAPhysical reference, or state " name " absolutely.")
          next
        }
        want = anchor_val - auth[ref]; if (want < 0) want = -want
        if (!num_eq(v, want))
          fail(FILENAME, FNR, name " = " val ", expected " want " (span from " anchor_name " = " anchor_val " down to LAPhysical." ref " = " authstr[ref] ").")
        next
      }
      if (!num_eq(v, auth[ref]))
        fail(FILENAME, FNR, name " = " val ", but LAPhysical." ref " = " authstr[ref] ". A physical constant is not a tuning knob: if the simulation needs " val ", the simulation is wrong. Fix the simulation, or correct the authority with a citation.")
      anchor_val = v; anchor_name = name
      next
    }

    # --- no reference: the watched-name heuristic ------------------------------------------------
    if (!literal) next
    u = toupper(name)
    if (u ~ /CHARGE/ && u ~ WATCH_CHARGE && u !~ MODEL_TOKENS) {
      fail(FILENAME, FNR, name " = " val " names the charge-separation band but carries no LAPhysical reference. The band has two endpoints (CHARGE_ZONE_WARM_C / CHARGE_ZONE_COLD_C) and no safe default, so say which: append \"// LAPhysical.CHARGE_ZONE_WARM_C\".")
      next
    }
    if (u ~ WATCH_RADIATION && u !~ MODEL_TOKENS) {
      rtarget = (u ~ /STEFAN/) ? "STEFAN_BOLTZMANN" : "SOLAR_CONSTANT_W_M2"
      if (!have[rtarget]) {
        fail(FILENAME, FNR, name " names a radiation constant but the authority defines no " rtarget ".")
        next
      }
      if (num_eq(v, auth[rtarget])) {
        printf "NOTE %s:%d  %s = %s agrees with LAPhysical.%s but is bound only by its value. Append \"// LAPhysical.%s\" to make it explicit.\n", rel(FILENAME), FNR, name, val, rtarget, rtarget
        notes++
        next
      }
      fail(FILENAME, FNR, name " = " val " names a radiation constant but is neither annotated LAPhysical." rtarget " nor equal to it (" authstr[rtarget] "). Solar irradiance and the Stefan-Boltzmann constant are measured facts. This kernel once ran SOLAR_CONSTANT = 600.0, \"sized so the sub-solar point equilibrates near 300 K\" — fitting the star to the planet. Do not re-dim the sun.")
      next
    }
    if (u !~ WATCH_PHASE || u ~ MODEL_TOKENS || u ~ OTHER_MATTER) next
    target = (u ~ /FREEZE/) ? "WATER_FREEZE_C" : ((u ~ /MELT|THAW/) ? "WATER_MELT_C" : "WATER_BOIL_C")
    if (!have[target]) {
      fail(FILENAME, FNR, name " names a water phase point but the authority defines no " target ".")
      next
    }
    if (num_eq(v, auth[target])) {
      printf "NOTE %s:%d  %s = %s agrees with LAPhysical.%s but is bound only by its value. Append \"// LAPhysical.%s\" to make it explicit.\n", rel(FILENAME), FNR, name, val, target, target
      notes++
      next
    }
    fail(FILENAME, FNR, name " = " val " names a water phase point but is neither annotated LAPhysical." target " nor equal to it (" authstr[target] "). A physical constant is not a tuning knob — a value fitted to make the sim look right is a lie about the material. If you meant a different quantity, name it in a trailing LAPhysical comment.")
  }

  END {
    printf "\nPhysical-constants gate: %d kernel constants scanned across %d files, %d violation(s), %d note(s).\n", checked, files, errors, notes
    exit(errors > 0 ? 1 : 0)
  }
' "${kernels[@]}"
rc=$?
set -e

if [[ $rc -ne 0 ]]; then
  echo
  echo "The authority is ${AUTHORITY#"$REPO_ROOT"/} (class LAPhysical)."
  echo "A physical constant is a measured property of matter. If one has to move for the simulation to"
  echo "look right, the simulation is wrong — fix the simulation, not the constant."
  exit 1
fi
echo "Physical-constants check passed (${auth_count} authoritative constants; ${#kernels[@]} kernels)."
