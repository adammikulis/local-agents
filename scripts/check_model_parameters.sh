#!/usr/bin/env bash
# =====================================================================================================
# MODEL-PARAMETERS GATE — every number is derived, bound, or written down. There is no fourth option.
#
# WHY THIS EXISTS. CLAUDE.md's second rule says a departure from real physics needs the maintainer's
# consent, asked first, and closes with "Prose rules did not hold on this repo; gates did." It then cites
# THIS script and docs/MODEL_PARAMETERS.md as the enforcement. Neither existed until 2026-08-10, so for as
# long as that rule has been written down, the sentence claiming gates beat prose was itself prose.
#
# check_physical_constants.sh answers "does this copy equal the authority". It cannot answer the prior
# question: SHOULD this be a number at all, and if so, who decided? A value that is not a property of
# matter is a MODELLING CHOICE, and a modelling choice that nobody wrote down is indistinguishable from a
# value someone fitted until the output looked right. That is the defect this repo keeps producing.
#
# THE RULE. A numeric constant passes if any of:
#   1. It is BOUND — a trailing comment names LAPhysical.<NAME> or LASubstances.<NAME>. Whether the value
#      is correct is check_physical_constants.sh's job, not this one.
#   2. It is DERIVED — the right-hand side is an expression over other constants rather than a literal.
#      A relation is structural; a literal is an assertion.
#   3. It is DECLARED — file and name appear in docs/MODEL_PARAMETERS.md with a reason and, crucially,
#      the condition under which it gets DELETED.
# Anything else fails the build.
#
# THE REGISTRY IS A DELETION QUEUE, NOT A HOME. Every entry names what would have to exist for the number
# to stop being needed. An entry that has sat there without that field is a value nobody intends to fix.
#
# SCOPE. GLSL kernels AND the GDScript simulation layer. The .gd half is not optional: AtmospherePass.gd
# declared AIR_DENSITY_KG_M3 = 1.225 while PhysicalConstants.gd said 1.18, a 4% split between two files
# describing the same air, and the GLSL-only gate could not see it.
#
# EXIT CODES. 0 pass · 1 violations · 2 the gate could not run (missing input), never a silent pass.
# =====================================================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KERNEL_DIR="$REPO_ROOT/addons/local_agents/sim/material/kernels3d"
SIM_DIR="$REPO_ROOT/addons/local_agents/sim"
REGISTRY="$REPO_ROOT/docs/MODEL_PARAMETERS.md"

# The authorities describe matter. They are the thing everything else is measured against, so they are not
# themselves subject to this gate.
AUTHORITY_FILES="PhysicalConstants.gd Substances.gd"

EMIT=0
[[ "${1:-}" == "--emit" ]] && EMIT=1

if [[ ! -d "$KERNEL_DIR" ]]; then
  echo "ERROR: kernel directory not found: $KERNEL_DIR" >&2
  exit 2
fi
if [[ ! -d "$SIM_DIR" ]]; then
  echo "ERROR: sim directory not found: $SIM_DIR" >&2
  exit 2
fi
if [[ $EMIT -eq 0 && ! -f "$REGISTRY" ]]; then
  echo "ERROR: registry not found: $REGISTRY" >&2
  echo "       Generate a starting point with: scripts/check_model_parameters.sh --emit > docs/MODEL_PARAMETERS.md" >&2
  echo "       A gate whose input is missing FAILS. It does not pass." >&2
  exit 2
fi

# `find`, not a glob: bash 3.2 ships without globstar, so `**/*.gd` silently collapses to ONE directory
# level and everything under sim/material/sphere_passes/ goes unscanned. That is where AtmospherePass.gd
# declares the second air density, i.e. the exact defect this gate was widened to catch.
scanned=()
while IFS= read -r f; do
  base="${f##*/}"
  skip=0
  for a in $AUTHORITY_FILES; do [[ "$base" == "$a" ]] && skip=1; done
  [[ $skip -eq 0 ]] && scanned+=("$f")
done < <(find "$KERNEL_DIR" -type f \( -name '*.glsl' -o -name '*.glsli' \) -print; find "$SIM_DIR" -type f -name '*.gd' -print)

if [[ ${#scanned[@]} -eq 0 ]]; then
  echo "ERROR: zero files to scan — refusing to report a pass on an empty comparison." >&2
  exit 2
fi

REG_INPUT="$REGISTRY"
[[ $EMIT -eq 1 && ! -f "$REGISTRY" ]] && REG_INPUT=/dev/null

set +e
awk -v REG="$REG_INPUT" -v ROOT="$REPO_ROOT/" -v EMIT="$EMIT" '
  function rel(p) { return (index(p, ROOT) == 1) ? substr(p, length(ROOT) + 1) : p }

  BEGIN {
    # --- the registry: "<file>\t<NAME>" declared, or "*\t<NAME>" declared everywhere -----------------
    while ((getline line < REG) > 0) {
      if (line !~ /^[ \t]*\|/) continue
      n = split(line, cell, "|")
      if (n < 4) continue
      fpath = cell[2]; cname = cell[3]
      gsub(/[` \t]/, "", fpath); gsub(/[` \t]/, "", cname)
      if (cname == "" || cname == "constant" || cname ~ /^-+$/) continue
      declared[fpath "\t" cname] = 1
      declared_any[cname] = declared_any[cname] " " fpath
    }
    close(REG)
    # A literal, with an optional GLSL float suffix.
    LIT = "^[-+]?([0-9]+\\.?[0-9]*|\\.[0-9]+)([eE][-+]?[0-9]+)?[fFuU]?$"
  }

  {
    line = $0
    # comment start: // for GLSL, # for GDScript
    ci = index(line, "//")
    hi = index(line, "#")
    if (ci == 0 || (hi > 0 && hi < ci)) ci = hi
    decl = (ci ? substr(line, 1, ci - 1) : line)
    cmt  = (ci ? substr(line, ci)        : "")

    if (decl !~ /(^|[ \t])const[ \t]/) next

    # GLSL:  const float NAME = value;      GDScript:  const NAME: float = value
    if (match(decl, /const[ \t]+(float|int|uint|vec[234])[ \t]+[A-Za-z_][A-Za-z0-9_]*/)) {
      seg = substr(decl, RSTART, RLENGTH); nf = split(seg, p, /[ \t]+/); name = p[nf]
    } else if (match(decl, /const[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]*:[ \t]*(float|int)/)) {
      seg = substr(decl, RSTART, RLENGTH); sub(/^.*const[ \t]+/, "", seg); sub(/[ \t]*:.*$/, "", seg); name = seg
    } else next

    eq = index(decl, "=")
    if (!eq) next
    val = substr(decl, eq + 1); sub(/;.*$/, "", val); gsub(/^[ \t]+|[ \t]+$/, "", val)
    if (val == "") next

    # 2. DERIVED — an expression, not an assertion. Structural by construction.
    if (val !~ LIT) next

    total++
    key = rel(FILENAME) "\t" name

    # 1. BOUND — the value question belongs to check_physical_constants.sh.
    if (cmt ~ /LAPhysical\.[A-Za-z0-9_]+/ || cmt ~ /LASubstances\.[A-Za-z0-9_]+/) { bound++; next }

    # 3. DECLARED
    if ((key in declared) || (("*" "\t" name) in declared)) { decl_ok++; next }

    if (EMIT) {
      printf "| `%s` | `%s` | %s | | |\n", rel(FILENAME), name, val
      emitted++
      next
    }
    printf "FAIL %s:%d  %s = %s is neither bound to LAPhysical/LASubstances, nor derived from other constants, nor declared in docs/MODEL_PARAMETERS.md.\n", rel(FILENAME), FNR, name, val
    if (val ~ /^-?[0-9]+$/) printf "      (if this is a TAG rather than a quantity — a mode, a slot, a bitflag — make it an `enum`. The registry is for numbers somebody CHOSE.)\n"
    errors++
  }

  END {
    if (EMIT) {
      printf "\n<!-- emitted %d undeclared constants of %d literal constants scanned -->\n", emitted, total > "/dev/stderr"
      exit 0
    }
    printf "\nModel-parameters gate: %d literal constants scanned — %d bound, %d declared, %d undeclared.\n", total, bound, decl_ok, errors
    exit(errors > 0 ? 1 : 0)
  }
' "${scanned[@]}"
rc=$?
set -e

if [[ $EMIT -eq 1 ]]; then exit 0; fi

# --- THE RATCHET: the registry may shrink and may not grow -------------------------------------------
# Declaring a constant is not absolution, it is an admission with an address. Without a ceiling the
# registry becomes the place numbers go to be permanently fine, which is worse than no registry because it
# reads as review. So the count is capped in the file itself: to add a number you must derive it, bind it,
# or raise MAX_DECLARED — and that raise is one visible line in the diff for someone to argue with.
rows="$(awk '/^[ \t]*\|/ { n = split($0, c, "|"); if (n < 4) next; nm = c[3]; gsub(/[` \t]/, "", nm); if (nm == "" || nm == "constant" || nm ~ /^-+$/) next; count++ } END { print count + 0 }' "$REGISTRY")"
cap="$(awk 'match($0, /MAX_DECLARED:[ \t]*[0-9]+/) { s = substr($0, RSTART, RLENGTH); gsub(/[^0-9]/, "", s); print s; exit }' "$REGISTRY")"
if [[ -z "$cap" ]]; then
  echo "ERROR: ${REGISTRY#"$REPO_ROOT"/} declares no 'MAX_DECLARED: <n>' ceiling. The registry without a" >&2
  echo "       ceiling is an amnesty, not a queue. Add the line." >&2
  exit 2
fi
if [[ "$rows" -gt "$cap" ]]; then
  echo "FAIL  ${REGISTRY#"$REPO_ROOT"/} holds $rows declared constants against a ceiling of $cap."
  echo
  echo "The registry is a DELETION QUEUE. It may shrink and it may not grow. If this number genuinely has"
  echo "to be a modelling choice, raise MAX_DECLARED in the same commit and say why in the message."
  exit 1
fi
# --- NO GHOST ROWS: a declared constant that no longer exists must leave the registry ------------------
# Without this the queue only ever grows stale: a row for a deleted (or since-derived) constant still counts
# toward the ceiling, so deleting code stops lowering the number and the ratchet quietly stops meaning
# anything. The rename of scent_fert_sphere3d.glsl -> fert_sphere3d.glsl is the case that showed it: three
# rows kept pointing at a path that no longer existed and nothing said so.
ghosts=0
while IFS=$'\t' read -r gfile gname; do
  [[ -z "$gname" || "$gfile" == "*" ]] && continue
  case " $AUTHORITY_FILES " in *" ${gfile##*/} "*) continue ;; esac
  if [[ ! -f "$REPO_ROOT/$gfile" ]]; then
    echo "FAIL  ${REGISTRY#"$REPO_ROOT"/}: \`$gname\` is declared against $gfile, which does not exist."
    ghosts=$((ghosts + 1))
  elif ! grep -Eq "(^|[[:space:]])const[[:space:]]+([A-Za-z0-9_]+[[:space:]]+)?${gname}([[:space:]]*[:=]|[[:space:]])" "$REPO_ROOT/$gfile"; then
    echo "FAIL  ${REGISTRY#"$REPO_ROOT"/}: \`$gname\` is declared but no longer exists in $gfile."
    ghosts=$((ghosts + 1))
  fi
done < <(awk '/^[ \t]*\|/ { n = split($0, c, "|"); if (n < 4) next; f = c[2]; nm = c[3]; gsub(/[` \t]/, "", f); gsub(/[` \t]/, "", nm); if (nm == "" || nm == "constant" || nm ~ /^-+$/) next; printf "%s\t%s\n", f, nm }' "$REGISTRY")
if [[ $ghosts -gt 0 ]]; then
  echo
  echo "Delete those rows. A registry entry for a constant that is gone is not a record, it is a ghost that"
  echo "holds the ceiling up and makes the ratchet stop measuring anything."
  exit 1
fi

if [[ "$rows" -lt "$cap" ]]; then
  echo "NOTE  registry is $((cap - rows)) below its ceiling — lower MAX_DECLARED to $rows to bank the progress."
fi

if [[ $rc -ne 0 ]]; then
  echo
  echo "Every number is derived, bound, or written down. A value that is none of those is a modelling"
  echo "choice nobody made on purpose, and it is indistinguishable from one fitted until the output looked"
  echo "right. Declare it in ${REGISTRY#"$REPO_ROOT"/} with the condition that DELETES it, or derive it."
  exit 1
fi
echo "Model-parameters check passed (${#scanned[@]} files)."
