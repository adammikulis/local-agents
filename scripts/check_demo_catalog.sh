#!/usr/bin/env bash
# Gate: the demo catalogue in addons/local_agents/examples/demos/ describes every demo exactly once, one
# LocalAgentDemoEntry resource per demo.

# A DEMO is a .tscn directly in addons/local_agents/examples/ other than DemoLauncher.tscn and other than
# a fragment (scripts/lib_demo_fragment.sh). An entry may point outside examples/, as game/VoxelWorld.tscn
# does; that scene must resolve but needs no entry.

# FAILS WHEN a demo scene has no entry · an entry's `scene_path` does not resolve · two entries share an
# `order` · a .tres in demos/ is not a LocalAgentDemoEntry · addons/local_agents/docs/DEMOS.md differs
# from what `gen_demos_doc.sh --check` renders.

# Parses .tres as text; takes no editor lock.
#   scripts/check_demo_catalog.sh            # table + verdict
#   scripts/check_demo_catalog.sh --quiet    # verdict only
# Exit 0 consistent · 1 not · 2 could not run.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
. "$ROOT/scripts/lib_demo_fragment.sh" || exit 2

EXAMPLES_DIR="addons/local_agents/examples"
CATALOG_DIR="$EXAMPLES_DIR/demos"
ENTRY_SCRIPT="res://addons/local_agents/examples/DemoEntry.gd"
# The catalogue viewer itself. Not a demo; everything else in examples/ is, unless it is a fragment.
LAUNCHER="DemoLauncher.tscn"

QUIET=0
if [[ "${1:-}" == "--quiet" ]]; then QUIET=1; fi

if [[ ! -d "$CATALOG_DIR" ]]; then
  echo "check_demo_catalog: FAIL, no catalogue directory at $CATALOG_DIR"
  exit 1
fi

# --- Parse every entry ------------------------------------------------------------------------
# One record per .tres: order|scene_path|title|requires_model|requires_voxel_backend|is_entry.
# Godot omits a property left at its default; each field defaults here as in DemoEntry.gd.
parse_entry() {
  awk -v entry_script="$ENTRY_SCRIPT" '
    /^\[ext_resource/ {
      if ($0 ~ /type="Script"/ && index($0, "path=\"" entry_script "\"")) is_entry = 1;
      next
    }
    /^order = /  { order = $3; next }
    /^title = "/ { if (match($0, /"[^"]*"/)) title = substr($0, RSTART+1, RLENGTH-2); next }
    /^scene_path = "/ { if (match($0, /"[^"]*"/)) scene = substr($0, RSTART+1, RLENGTH-2); next }
    /^requires_model = /          { model = $3; next }
    /^requires_voxel_backend = /  { voxel = $3; next }
    END {
      if (order == "") order = 0;
      if (model == "") model = "false";
      if (voxel == "") voxel = "false";
      printf "%s|%s|%s|%s|%s|%s\n", order, scene, title, model, voxel, (is_entry ? "yes" : "no");
    }
  ' "$1"
}

errors=0
rows=""
declare -a orders_seen=()
declare -a scene_paths=()

shopt -s nullglob
tres_files=("$CATALOG_DIR"/*.tres)
shopt -u nullglob

if [[ ${#tres_files[@]} -eq 0 ]]; then
  echo "check_demo_catalog: FAIL, no entries in $CATALOG_DIR"
  exit 1
fi

for tres in "${tres_files[@]}"; do
  record="$(parse_entry "$tres")"
  IFS='|' read -r order scene title model voxel is_entry <<< "$record"
  base="$(basename "$tres")"

  if [[ "$is_entry" != "yes" ]]; then
    echo "  ERROR $base: not a LocalAgentDemoEntry (no ext_resource for $ENTRY_SCRIPT)"
    errors=$((errors + 1))
    continue
  fi

  if [[ -z "$scene" ]]; then
    echo "  ERROR $base: no scene assigned"
    errors=$((errors + 1))
  else
    scene_file="${scene#res://}"
    if [[ ! -f "$scene_file" ]]; then
      echo "  ERROR $base: scene does not resolve: $scene"
      errors=$((errors + 1))
    fi
    scene_paths+=("$scene")
  fi

  for seen in "${orders_seen[@]:-}"; do
    if [[ -n "$seen" && "${seen%%:*}" == "$order" ]]; then
      echo "  ERROR $base: duplicate order $order (also ${seen#*:})"
      errors=$((errors + 1))
    fi
  done
  orders_seen+=("$order:$base")

  flags=""
  [[ "$model" == "true" ]] && flags="${flags}model "
  [[ "$voxel" == "true" ]] && flags="${flags}voxel "
  [[ -z "$flags" ]] && flags="-"
  rows+="$(printf '  %4s  %-26s %-34s %s' "$order" "$base" "$title" "$flags")"$'\n'
done

# --- Every demo scene must be catalogued ---------------------------------------------------------
missing=""
for scene_file in "$EXAMPLES_DIR"/*.tscn; do
  base="$(basename "$scene_file")"
  [[ "$base" == "$LAUNCHER" ]] && continue
  if demo_fragment_parent "$ROOT" "$scene_file" >/dev/null; then continue; fi
  want="res://$scene_file"
  found=0
  for have in "${scene_paths[@]:-}"; do
    if [[ "$have" == "$want" ]]; then found=1; break; fi
  done
  if [[ "$found" -eq 0 ]]; then
    missing+="  ERROR $base: no catalogue entry, add a .tres in $CATALOG_DIR"$'\n'
    errors=$((errors + 1))
  fi
done
[[ -n "$missing" ]] && printf '%s' "$missing"

# --- The generated demo page must match the catalogue --------------------------------------------
GEN_DOC="$ROOT/scripts/gen_demos_doc.sh"
if [[ ! -x "$GEN_DOC" ]]; then
  # A missing generator is an error, never a skip.
  echo "  ERROR scripts/gen_demos_doc.sh: missing or not executable, cannot verify docs/DEMOS.md"
  errors=$((errors + 1))
else
  set +e
  doc_out="$("$GEN_DOC" --check 2>&1)"
  rc_doc=$?
  set -e
  if [[ "$rc_doc" -ne 0 ]]; then
    # --quiet: the verdict line only.
    if [[ "$QUIET" -eq 1 ]]; then
      printf '%s\n' "$doc_out" | tail -n 1 | sed 's/^/  /'
    else
      printf '%s\n' "$doc_out" | sed 's/^/  /'
    fi
    errors=$((errors + 1))
  fi
fi

if [[ "$QUIET" -eq 0 && "$errors" -eq 0 ]]; then
  echo "check_demo_catalog: ${#tres_files[@]} entries"
  printf '  %4s  %-26s %-34s %s\n' "ord" "entry" "title" "gated on"
  printf '%s' "$(printf '%s' "$rows" | sort -n)"
  echo ""
fi

if [[ "$errors" -eq 0 ]]; then
  echo "check_demo_catalog: OK (${#tres_files[@]} entries, every examples/*.tscn demo catalogued, docs/DEMOS.md in sync)"
  exit 0
fi
echo "check_demo_catalog: FAIL ($errors error(s))"
exit 1
