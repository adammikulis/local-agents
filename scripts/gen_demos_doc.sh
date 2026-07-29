#!/usr/bin/env bash
# Generate addons/local_agents/docs/DEMOS.md from the demo catalogue.
#
# The demo list used to be written by hand in three places (a `const DEMOS` array in the launcher, a
# table in README.md, prose in docs/USAGE.md). All three disagreed, and two demos appeared in none of
# them. The catalogue in addons/local_agents/examples/demos/ is now the one source, so the
# human-readable page is rendered from it rather than typed a fourth time.
#
#   scripts/gen_demos_doc.sh           # write addons/local_agents/docs/DEMOS.md
#   scripts/gen_demos_doc.sh --check   # compare the checked-in file against a fresh render
#
# Exit 0 when the file is written, or when --check finds it already current. Exit 1 when --check
# finds drift (it prints the diff first, then the verdict), or when the catalogue cannot be rendered.
# scripts/check_demo_catalog.sh runs the --check mode, and scripts/agent_harness.sh lint runs that,
# so a stale page fails lint.
#
# The .tres files are parsed as text, by the same rules scripts/check_demo_catalog.sh uses:
#   * a property left at its default is omitted by Godot when it saves the resource, so every field
#     defaults here exactly as it does in examples/DemoEntry.gd;
#   * the id match carries a leading space, because a bare /id="/ matches inside uid="..." first
#     (leftmost match) and would read the uid as the resource id on any editor-resaved file.
# `description` is @export_multiline, so Godot still writes it on one line and escapes a newline as
# the two characters \n. Those are turned back into real newlines here, as is \". A literal backslash
# in a description is not unescaped, and no entry has one. Text parsing takes no editor lock and runs
# in milliseconds, so this is safe to run beside scripts/editor_scan.sh.
#
# Environment notes that have already cost this repo time: macOS ships bash 3.2, so no mapfile and no
# associative arrays. Every expansion is quoted, the maintainer's interactive shell is zsh. `set -e`
# plus a grep that legitimately matches nothing kills a script, so every grep here is an `if`
# condition. The output carries no timestamp and no absolute path on purpose, otherwise --check would
# report drift on every run.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

EXAMPLES_DIR="addons/local_agents/examples"
CATALOG_DIR="$EXAMPLES_DIR/demos"
DOC_PATH="addons/local_agents/docs/DEMOS.md"
ENTRY_SCRIPT="res://addons/local_agents/examples/DemoEntry.gd"
LAUNCHER_SCENE="$EXAMPLES_DIR/DemoLauncher.tscn"
WINDOWED_RUNNER="scripts/run_sim_offscreen.sh"
# scripts/run_demo.sh: DEFAULT_FRAMES="${LA_DEMO_FRAMES:-40}".
DEFAULT_FRAMES=40

MODE="write"
case "${1:-}" in
  "")      MODE="write" ;;
  --check) MODE="check" ;;
  -h|--help)
    echo "Usage: scripts/gen_demos_doc.sh [--check]"
    echo "  (no argument)  render $DOC_PATH from $CATALOG_DIR"
    echo "  --check        exit 1 with a diff if the checked-in file is not what would be rendered"
    exit 0
    ;;
  *)
    echo "gen_demos_doc: unknown argument '$1', expected --check or no argument" >&2
    exit 2
    ;;
esac

if [[ ! -d "$CATALOG_DIR" ]]; then
  echo "gen_demos_doc: FAIL, no catalogue directory at $CATALOG_DIR"
  exit 1
fi

shopt -s nullglob
tres_files=("$CATALOG_DIR"/*.tres)
shopt -u nullglob

if [[ ${#tres_files[@]} -eq 0 ]]; then
  echo "gen_demos_doc: FAIL, no entries in $CATALOG_DIR"
  exit 1
fi

# --- Parsing ------------------------------------------------------------------------------------
# order|scene|requires_model|requires_voxel_backend|is_entry_resource. `title` and `description` are
# fetched separately by entry_text: they are free text that may contain a pipe or a newline, which no
# single-line record could carry.
parse_meta() {
  awk -v entry_script="$ENTRY_SCRIPT" '
    /^\[ext_resource/ {
      type=""; path=""; id="";
      if (match($0, /type="[^"]*"/)) type = substr($0, RSTART+6, RLENGTH-7);
      if (match($0, /path="[^"]*"/)) path = substr($0, RSTART+6, RLENGTH-7);
      if (match($0, / id="[^"]*"/))  id   = substr($0, RSTART+5, RLENGTH-6);
      if (id != "") res_path[id] = path;
      if (type == "Script" && path == entry_script) is_entry = 1;
      next
    }
    /^order = /                  { order = $3; next }
    # `scene_path = "res://..."` is the current form. The ExtResource branch stays for a .tres still
    # holding a PackedScene reference, so an un-migrated entry renders its scene rather than a blank.
    /^scene_path = "/            { if (match($0, /"[^"]*"/)) scene_direct = substr($0, RSTART+1, RLENGTH-2); next }
    /^scene = ExtResource\(/     { if (match($0, /"[^"]*"/)) scene_id = substr($0, RSTART+1, RLENGTH-2); next }
    /^requires_model = /         { model = $3; next }
    /^requires_voxel_backend = / { voxel = $3; next }
    END {
      if (order == "") order = 0;
      if (model == "") model = "false";
      if (voxel == "") voxel = "false";
      scene = (scene_direct != "") ? scene_direct : ((scene_id == "") ? "" : res_path[scene_id]);
      printf "%s|%s|%s|%s|%s\n", order, scene, model, voxel, (is_entry ? "yes" : "no");
    }
  ' "$1"
}

# One @export String field, unescaped. The prefix test is a plain string compare rather than a regex,
# so a field name never has to be escaped, and `requires_model` can never match inside
# `requires_voxel_backend`.
entry_text() {
  awk -v want="$2" '
    index($0, want " = \"") == 1 {
      value = substr($0, length(want) + 5)
      sub(/"$/, "", value)
      gsub(/\\"/, "\"", value)
      gsub(/\\n/, "\n", value)
      next
    }
    END { print value }
  ' "$1"
}

# A scene honours --run-frames when it, or its sibling script, builds a LocalAgentDemoHarness. Same
# test scripts/run_demo.sh makes, so this page cannot claim a command that script would refuse.
scene_has_harness() {
  grep -qs 'DemoHarness' "$EXAMPLES_DIR/$1.gd" "$EXAMPLES_DIR/$1.tscn"
}

# --- Rendering ----------------------------------------------------------------------------------
requires_line() {
  local model="$1" voxel="$2"
  if [[ "$model" == "true" && "$voxel" == "true" ]]; then
    echo 'a GGUF model installed, and the godot_voxel GDExtension (addons/zylann.voxel/)'
  elif [[ "$model" == "true" ]]; then
    echo 'a GGUF model installed'
  elif [[ "$voxel" == "true" ]]; then
    echo 'the godot_voxel GDExtension (addons/zylann.voxel/)'
  else
    echo 'nothing, it opens with no model installed'
  fi
}

# The bullet is labelled from the same branch that picks the command, so a scene that cannot run
# headless is never described as if it could.
run_label() {
  local scene_rel="$1"
  if [[ "$(dirname "$scene_rel")" != "$EXAMPLES_DIR" ]]; then echo "Run"; else echo "Run headless"; fi
}

# The harness rule itself is stated once in the header, so the per-demo line is the command plus the
# short reason it is that command and not another.
run_line() {
  local scene_rel="$1"
  local name
  name="$(basename "$scene_rel" .tscn)"
  if [[ "$(dirname "$scene_rel")" != "$EXAMPLES_DIR" ]]; then
    printf '`%s --path . %s -- --run-frames=200`. It lives outside `%s/`, so `scripts/run_demo.sh` cannot address it, and headless has no compute device for its field, so the wrapper gives it a real window placed off-screen.\n' \
      "$WINDOWED_RUNNER" "$scene_rel" "$EXAMPLES_DIR"
  elif scene_has_harness "$name"; then
    printf '`scripts/run_demo.sh %s`, or `scripts/run_demo.sh %s 200` for more than the default %s frames.\n' \
      "$name" "$name" "$DEFAULT_FRAMES"
  else
    printf '`godot --headless --path . %s --quit-after 120`, since it builds no harness.\n' "$scene_rel"
  fi
}

write_header() {
  local out="$1" total="$2" harnessed="$3" outside="$4"
  {
    echo '# Demos'
    echo ''
    printf 'The demo ladder is %s scenes ordered simplest first. To open them, double-click\n' "$total"
    printf '`%s` in the FileSystem dock, then click Run Current\n' "$LAUNCHER_SCENE"
    cat <<'MD'
Scene in the top-right toolbar. The launcher builds its rows from the catalogue this page comes
from: one `LocalAgentDemoEntry` resource per demo in `addons/local_agents/examples/demos/`. Drop a
`.tres` in that directory and a row appears in the launcher with no code to edit. The numbering
below is the launcher's own, taken from each entry's `order`.
MD
    echo ''
    # Every claim here is one branch of LocalAgentDemoLauncher.gate_reason(), in its order. The
    # model branch is the one that surprises people: a row that names a model still opens when the
    # weights are on disk but not loaded, because the demo loads them itself.
    cat <<'MD'
A row whose Requires line names a GGUF model still opens when the file is on disk but has not been
loaded yet, since the demo loads it itself. The launcher greys that row out when the install is
missing something harder:

- the native extension did not load
- the AgentManager autoload is missing
- no `.gguf` file was found at all

A row that needs the godot_voxel GDExtension is greyed out when `addons/zylann.voxel/` is not
installed. Every other row opens no matter what is installed. `INSTALL.md` covers where a model comes
from and where to put it.
MD
    echo ''
    cat <<'MD'
This page is generated by `scripts/gen_demos_doc.sh`. Run that script after you add or edit a
`.tres`, or `scripts/check_demo_catalog.sh` fails the build until the page matches the catalogue
again. Editing the page by hand does not last, because the next run of the generator overwrites your
text. Change the `.tres` for content, or the generator for wording.
MD
    echo ''
    echo '## Running a demo headless'
    echo ''
    # Scoped to `an example scene` on purpose. `--run-frames` has a second implementation outside
    # examples/ (game/world/VoxelInputController.gd parses it, game/world/VoxelHarness.gd prints the
    # report and quits), so the unscoped form of this sentence was false for the entry outside that
    # directory, which is handed --run-frames by its own command below.
    cat <<'MD'
`scripts/run_demo.sh <name>` runs an example scene with no window in about a second and prints a
`RUN_DEMO={...}` line carrying the exit code. It only accepts a scene that builds a
MD
    printf '`LocalAgentDemoHarness`, and %s of the %s entries have one. An example scene without that harness\n' \
      "$harnessed" "$total"
    cat <<'MD'
ignores `--run-frames` and never exits, so it gets `--quit-after` instead. Each demo below carries
the command that applies to it.
MD
    echo ''
    printf '`scripts/run_demo.sh --all` runs every harnessed demo in turn at %s frames each, then prints a\n' \
      "$DEFAULT_FRAMES"
    cat <<'MD'
`RUN_DEMO_ALL={"ran":N,"failed":N,"frames":N}` line and exits non-zero if any of them failed. Pass a
frame count to override the default, as in `scripts/run_demo.sh --all 200`.
MD
    echo ''
    cat <<'MD'
`scripts/run_demo.sh --list` prints which is which. It walks the scenes in
MD
    printf '`%s/` rather than the catalogue, so it also lists `%s`,\n' \
      "$EXAMPLES_DIR" "$(basename "$LAUNCHER_SCENE")"
    if [[ -n "$outside" ]]; then
      printf 'the catalogue viewer, and it leaves out whatever the catalogue points to outside that\n'
      printf 'directory: %s.\n' "$outside"
      echo ''
      cat <<'MD'
`LocalAgentDemoHarness` is not the only implementation of `--run-frames`. Whatever the catalogue
points to outside that directory parses the flag in its own scripts and quits when it reaches the
frame count, which is why the command for it below hands `--run-frames` to a scene with no harness.
MD
    else
      printf 'the catalogue viewer, which is not itself a demo.\n'
    fi
    echo ''
    cat <<'MD'
To see what the launcher makes of the catalogue on this machine, including which rows it greys out
and why, run:
MD
    echo ''
    printf '    godot --headless --path . %s -- --catalog-report\n' "$LAUNCHER_SCENE"
    echo ''
    echo 'It prints a `DEMO_CATALOG={...}` line and quits.'
  } >> "$out"
}

# Each section opens with the blank line that separates it from what came before, and ends on its
# last bullet. Emitting the separator trailing instead would leave the file ending in a blank line,
# which is a diff --check would report on a file nobody had touched.
write_demo() {
  local out="$1" pos="$2" tres="$3" scene="$4" model="$5" voxel="$6"
  local title description scene_rel
  title="$(entry_text "$tres" title)"
  description="$(entry_text "$tres" description)"
  [[ -n "$title" ]] || title="$(basename "$tres" .tres)"

  {
    echo ''
    printf '## %s. %s\n' "$pos" "$title"
    if [[ -n "$description" ]]; then
      printf '\n%s\n' "$description"
    fi
    echo ''
    if [[ -z "$scene" ]]; then
      printf -- '- Scene: none assigned in `%s`\n' "$tres"
      printf -- '- Requires: %s\n' "$(requires_line "$model" "$voxel")"
      printf -- '- Run: nothing to run until the entry names a scene.\n'
    else
      scene_rel="${scene#res://}"
      printf -- '- Scene: `%s`\n' "$scene"
      printf -- '- Requires: %s\n' "$(requires_line "$model" "$voxel")"
      printf -- '- %s: %s\n' "$(run_label "$scene_rel")" "$(run_line "$scene_rel")"
    fi
  } >> "$out"
}

generate() {
  local out="$1"
  local tres order scene model voxel is_entry scene_rel name
  local index="" total=0 harnessed=0 outside=""

  for tres in "${tres_files[@]}"; do
    IFS='|' read -r order scene model voxel is_entry <<< "$(parse_meta "$tres")"
    if [[ "$is_entry" != "yes" ]]; then
      echo "gen_demos_doc: FAIL, $tres is not a LocalAgentDemoEntry (no ext_resource for $ENTRY_SCRIPT)" >&2
      return 1
    fi
    index="${index}${order}"$'\t'"${tres}"$'\n'
  done

  # Sort on the order field, then on the path, so two entries sharing an order still render in a
  # fixed sequence. (Sharing one is a catalogue error, and scripts/check_demo_catalog.sh reports it.)
  # The herestring keeps this loop in the current shell, so the counts it accumulates survive it.
  : > "$body"
  while IFS=$'\t' read -r order tres; do
    [[ -n "$tres" ]] || continue
    IFS='|' read -r order scene model voxel is_entry <<< "$(parse_meta "$tres")"
    total=$((total + 1))
    if [[ -n "$scene" ]]; then
      scene_rel="${scene#res://}"
      name="$(basename "$scene_rel" .tscn)"
      if [[ "$(dirname "$scene_rel")" == "$EXAMPLES_DIR" ]]; then
        if scene_has_harness "$name"; then harnessed=$((harnessed + 1)); fi
      else
        if [[ -n "$outside" ]]; then outside="$outside, "; fi
        outside="$outside$(printf '`%s`' "$scene_rel")"
      fi
    fi
    write_demo "$body" "$total" "$tres" "$scene" "$model" "$voxel"
  done <<< "$(printf '%s' "$index" | sort -t$'\t' -k1,1n -k2,2)"

  : > "$out"
  write_header "$out" "$total" "$harnessed" "$outside"
  cat "$body" >> "$out"
}

# --- Modes --------------------------------------------------------------------------------------
rendered="$(mktemp -t la_demos_doc)"
body="$(mktemp -t la_demos_body)"
diff_out="$(mktemp -t la_demos_diff)"
trap 'rm -f "$rendered" "$body" "$diff_out"' EXIT

generate "$rendered"

if [[ "$MODE" == "write" ]]; then
  mkdir -p "$(dirname "$DOC_PATH")"
  # Redirect rather than `cp`: mktemp creates the render at 0600, and copying it over the doc handed
  # DEMOS.md that mode while every other file in docs/ was 0644. A redirect takes the umask on a new
  # file and leaves the mode alone on an existing one.
  cat "$rendered" > "$DOC_PATH"
  echo "gen_demos_doc: wrote $DOC_PATH (${#tres_files[@]} entries)"
  exit 0
fi

if [[ ! -f "$DOC_PATH" ]]; then
  echo "gen_demos_doc: FAIL, $DOC_PATH does not exist. Create it with scripts/gen_demos_doc.sh"
  exit 1
fi

# Labelled, so the reader is not asked to work out which side is the checked-in file from a mktemp
# path. macOS diff takes -L twice, same as GNU.
if diff -u -L "$DOC_PATH (checked in)" -L "$DOC_PATH (what the catalogue renders to)" \
    "$DOC_PATH" "$rendered" > "$diff_out" 2>&1; then
  echo "gen_demos_doc: OK ($DOC_PATH matches the catalogue, ${#tres_files[@]} entries)"
  exit 0
fi

head -n 60 "$diff_out"
diff_lines="$(wc -l < "$diff_out" | tr -d ' ')"
if [[ "$diff_lines" -gt 60 ]]; then
  echo "... and $((diff_lines - 60)) more diff lines, not shown"
fi
echo "gen_demos_doc: FAIL, $DOC_PATH is stale. Regenerate it with scripts/gen_demos_doc.sh"
exit 1
