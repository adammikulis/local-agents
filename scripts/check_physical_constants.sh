#!/usr/bin/env bash
# PHYSICAL CONSTANTS GATE — the GLSL copies must equal the one authority, LAPhysical in
# addons/local_agents/sim/material/PhysicalConstants.gd. A compute shader cannot import a GDScript
# constant, so every kernel declares its own copy; this stands in for the import the language lacks.

# 1. AN EXPLICIT REFERENCE IS A BINDING CONTRACT, and always beats the name heuristic in 2:
#        const float FREEZE_TEMP = 0.0;   // LAPhysical.WATER_FREEZE_C
#    "down to" or "span to" before the reference makes the constant a WIDTH — the distance from the
#    nearest preceding referenced constant in the same file to the named one. A parenthesised number
#    after the reference is checked too, so the comment cannot go stale while the code stays right.

# 2. A WATCHED NAME IS BOUND EVEN WITHOUT A COMMENT, so a fitted constant cannot arrive silently. A name
#    carrying a water phase point (FREEZE / MELT / THAW / BOIL) or the charge band (CHARGE with
#    FREEZE/ZONE/WARM/COLD) must either name its authority or already hold its value. Fitting satisfies
#    neither. Correct-but-undocumented passes with a NOTE. The charge band has two endpoints and no safe
#    default, so an unannotated CHARGE_* temperature always fails.

# 3. MODEL PARAMETERS ARE NOT TOUCHED. Rates, gains, fractions, thresholds, minima, capacities and
#    numerical guards are properties of the model, not of matter. The heuristic ignores any name carrying
#    RATE, FRAC, GAIN, SCALE, COEFF, MIN, MAX, THRESH, STEP, COUNT, DAMP, LEAK, SPAN, MASS, FLOW or DEPTH
#    (BOIL_RATE is a model parameter, BOIL_TEMP is not), and any name qualified by another material.

# SCOPE: the water phase points, the charge-separation band, the two radiation constants. Widen it in
# WATCHED_* below. Never list a quantity as "not watched yet because the kernel disagrees" — watch it and
# fix the kernel, or every later reader is told the disagreement is intentional.

# EXIT 0 clean · 1 a violation · 2 could not run (missing tool, authority, kernel directory, or an
# authority that parsed to zero constants). A gate that cannot run must fail, never pass.
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
# value slip out of this gate simply by being factored into a header.
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
# invisible to the gate on the day it was added: the gate gets quietly weaker as the authority gets
# better unless every declaration syntax is parsed.
SUBSTANCES="${LA_SUBSTANCE_AUTHORITY:-$REPO_ROOT/addons/local_agents/sim/material/Substances.gd}"
if [[ ! -f "$SUBSTANCES" ]]; then
  echo "ERROR: check_physical_constants.sh cannot find the substance table:" >&2
  echo "       $SUBSTANCES" >&2
  echo "       It is the authority for every property of matter, so a kernel copy of one is" >&2
  echo "       unverifiable without it." >&2
  exit 2
fi
if ! python3 "$SCRIPT_DIR/lib_parse_authority.py" "$AUTHORITY" "$SUBSTANCES" > "$AUTH_MAP"; then
  echo "check_physical_constants: the authority could not be parsed; see above." >&2
  exit 2
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
    # Rock is not water, so a rock phase point must not be checked against WATER_*. It is REDIRECTED to
    # BASALT_* below, not exempted: an exemption here is how a rock phase point survives unchecked.
    OTHER_MATTER = "(ROCK|BASALT|LAVA|MAGMA|IRON|METAL|SOLIDIF)"
    WATCH_ROCK_PHASE = "(SOLIDIF|SOLIDUS|LIQUIDUS)"
    WATCH_ALBEDO = "ALBEDO"
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

    # --- a property of a substance binds to the substance table, the SSOT for matter --------------
    if (match(cmt, /LASubstances\.[A-Za-z0-9_]+\.[A-Za-z0-9_]+/)) {
      ref = substr(cmt, RSTART, RLENGTH)
      if (!have[ref]) {
        fail(FILENAME, FNR, name " references " ref ", which the substance table does not give as a scalar property.")
        next
      }
      if (!literal) {
        fail(FILENAME, FNR, name " references " ref " but its value \"" val "\" is not a plain numeric literal, so the gate cannot verify it. Write the number.")
        next
      }
      if (!num_eq(v, auth[ref]))
        fail(FILENAME, FNR, name " = " val ", but " ref " = " authstr[ref] ". A measured property of a substance is declared once, in the table.")
      next
    }

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
    # --- the Kelvin offset is bound by its VALUE, because 273.15 is only ever one quantity ---------
    if (num_eq(v, 273.15) && have["KELVIN_OFFSET"]) {
      printf "NOTE %s:%d  %s = %s is the Kelvin offset but is bound only by its value. Append \"// LAPhysical.KELVIN_OFFSET\".\n", rel(FILENAME), FNR, name, val
      notes++
      next
    }

    # --- surface albedo -------------------------------------------------------------------------
    if (u ~ WATCH_ALBEDO && u !~ MODEL_TOKENS) {
      if (u ~ /(WATER|OCEAN|SEA)/) atarget = "ALBEDO_OCEAN"
      else if (u ~ /(ICE|SNOW)/) atarget = "ALBEDO_SNOW_ICE"
      else if (u ~ /(VEG|LEAF|CANOPY)/) atarget = "ALBEDO_VEGETATION"
      else atarget = "ALBEDO_BARE_GROUND"
      if (!have[atarget]) {
        fail(FILENAME, FNR, name " names a surface albedo but the authority defines no " atarget ".")
        next
      }
      if (num_eq(v, auth[atarget])) {
        printf "NOTE %s:%d  %s = %s agrees with LAPhysical.%s but is bound only by its value. Append \"// LAPhysical.%s\" to make it explicit.\n", rel(FILENAME), FNR, name, val, atarget, atarget
        notes++
        next
      }
      fail(FILENAME, FNR, name " = " val " names a surface albedo but is neither annotated LAPhysical." atarget " nor equal to it (" authstr[atarget] "). Albedo is a measured property of a surface.")
      next
    }

    # --- ROCK PHASE POINTS: redirected, not exempted ----------------------------------------------
    # A carve-out is where a wrong value hides: falling through OTHER_MATTER means scanned by nothing.
    if ((u ~ WATCH_ROCK_PHASE || (u ~ /(ROCK|BASALT|LAVA|MAGMA)/ && u ~ /(MELT|FREEZE)/)) && u !~ MODEL_TOKENS) {
      rtgt = (u ~ /(MELT|LIQUIDUS)/) ? "BASALT_LIQUIDUS_C" : "BASALT_SOLIDUS_C"
      if (!have[rtgt]) {
        fail(FILENAME, FNR, name " names a rock phase point but the authority defines no " rtgt ".")
        next
      }
      if (num_eq(v, auth[rtgt])) {
        printf "NOTE %s:%d  %s = %s agrees with LAPhysical.%s but is bound only by its value. Append \"// LAPhysical.%s\" to make it explicit.\n", rel(FILENAME), FNR, name, val, rtgt, rtgt
        notes++
        next
      }
      fail(FILENAME, FNR, name " = " val " names a rock phase point but is neither annotated LAPhysical." rtgt " nor equal to it (" authstr[rtgt] "). The solidus and liquidus of basalt are measured properties of the rock, not thresholds to tune.")
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
