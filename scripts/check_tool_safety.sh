#!/usr/bin/env bash
# Gate: a @tool node must never write a SERIALISED property while running in the editor. `@tool` runs
# _ready/_process/_physics_process/_enter_tree inside the editor, and an assignment to a serialised
# property there is recorded as a scene override and baked into the user's .tscn on the next save.

# FLAGGED only when BOTH hold, which is what keeps the false-positive rate low: the file declares
# `@tool` and has a lifecycle callback not guarded by an early `Engine.is_editor_hint()` return, AND it
# assigns a serialised property on a receiver it does not itself construct at run time.

# NOT CAUGHT, bash being no GDScript type checker: writes reached from a signal, a Timer, a
# `call_deferred` or a setter; properties outside SERIALISED_PROPS below; a guard present but not
# reachable first, since it need only appear within GUARD_WINDOW code lines; and a receiver assigned
# from `X.new()` anywhere in the file, whose every write is then treated as run-time-created. A local
# named like a serialised property counts as a write.

# EXEMPT: `extends EditorPlugin`, which only ever exists inside the editor, and the ALLOWLIST below —
# every entry needs a `#` reason directly above it or this refuses to run.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Overridable so the gate can be pointed at a fixture directory to prove it still catches a known
# offender pattern (see the self-test in the report for this script). Defaults to the addon.
SCAN_DIR="${LA_TOOL_SAFETY_SCAN_DIR:-addons/local_agents}"

# A missing or empty SCAN_DIR makes the `find` at the bottom produce nothing, the while loop never runs,
# `violations` stays empty and the gate prints OK — a pass earned by reading zero files. The pass
# condition here is the ABSENCE of an unguarded @tool write, so it is only worth anything if something
# was actually read. Exit 2 (could not run) rather than 0.
if [ ! -d "$SCAN_DIR" ]; then
  echo "check_tool_safety: scan directory '$SCAN_DIR' does not exist — nothing to check." >&2
  echo "check_tool_safety: FAIL (cannot run)" >&2
  exit 2
fi
scanned_gd=$(find "$SCAN_DIR" -name '*.gd' -type f | grep -c . || true)
if [ "${scanned_gd:-0}" -eq 0 ]; then
  echo "check_tool_safety: zero .gd files under '$SCAN_DIR'. Refusing to report a pass on zero files." >&2
  echo "check_tool_safety: FAIL (cannot run)" >&2
  exit 2
fi

# Properties Godot serialises into the .tscn. A write to one of these from editor-reachable code
# silently edits the user's scene.
SERIALISED_PROPS='text|visible|position|rotation|scale|placeholder_text|modulate'

# How many code lines (blank + comment lines are not counted) into a lifecycle callback body the
# `Engine.is_editor_hint()` guard may appear. ChatPanel._ready validates its node layout first, so
# the guard is not literally line 1; a small window accepts that without accepting a guard buried
# halfway down a function.
GUARD_WINDOW=8

# --- allowlist ---------------------------------------------------------------
# Files exempted from the gate. FORMAT: one `# reason` comment line immediately above each path.
# The reason must state why running in the editor is correct for that file. No comment => the
# script exits non-zero, so an entry cannot be added silently.
ALLOWLIST_RAW=$(cat <<'ENTRIES'
# Editor-dock UI: ChatController.tscn is embedded in editor/LocalAgentPanel.tscn, which plugin.gd
# preloads as PANEL_SCENE and instantiates as the dock. Running in the editor is its whole job; the
# widgets it paints are dock instances created at run time, never nodes in a user's saved scene.
addons/local_agents/controllers/ChatController.gd
# Editor-dock UI: editor/DownloadTab.tscn (this script) is an ext_resource of
# editor/LocalAgentPanel.tscn, the plugin dock. Same reasoning as ChatController.
addons/local_agents/controllers/DownloadController.gd
# Editor-dock UI: configuration/ui/ModelConfig.tscn is instanced inside
# editor/ConfigurationPanel.tscn, which is itself a tab of editor/LocalAgentPanel.tscn.
addons/local_agents/configuration/ui/ModelConfig.gd
# Editor-dock UI: configuration/ui/InferenceConfig.tscn is instanced inside
# editor/ConfigurationPanel.tscn, which is itself a tab of editor/LocalAgentPanel.tscn.
addons/local_agents/configuration/ui/InferenceConfig.gd
# Editor-dock UI: plugin.gd instantiates editor/SetupTab.tscn as the bottom panel before activation,
# and it is also the Setup tab of editor/LocalAgentPanel.tscn. It has no run-time caller at all, so
# Engine.is_editor_hint() is true on every path it has and an early return would leave the checklist
# blank in the one place it exists.
addons/local_agents/editor/SetupTab.gd
ENTRIES
)

allowlist=()
pending_comment=0
lineno=0
while IFS= read -r entry; do
  lineno=$((lineno + 1))
  case "$entry" in
    "" ) continue ;;
    \#* ) pending_comment=1; continue ;;
  esac
  if [ "$pending_comment" -eq 0 ]; then
    echo "check_tool_safety: allowlist entry '$entry' has no '#' reason comment above it." >&2
    echo "check_tool_safety: FAIL (malformed allowlist)" >&2
    exit 2
  fi
  if [ ! -f "$entry" ]; then
    echo "check_tool_safety: allowlist entry '$entry' does not exist — remove the stale entry." >&2
    echo "check_tool_safety: FAIL (stale allowlist)" >&2
    exit 2
  fi
  allowlist+=("$entry")
  pending_comment=0
done <<< "$ALLOWLIST_RAW"

is_allowlisted() {
  local candidate="$1"
  local item
  for item in "${allowlist[@]}"; do
    [ "$item" = "$candidate" ] && return 0
  done
  return 1
}

# --- scan --------------------------------------------------------------------
violations=""
tool_files=0
checked_files=0

while IFS= read -r file; do
  grep -qE '^[[:space:]]*@tool[[:space:]]*$' "$file" || continue
  tool_files=$((tool_files + 1))
  is_allowlisted "$file" && continue
  grep -qE '^[[:space:]]*extends[[:space:]]+EditorPlugin\b' "$file" && continue
  grep -qE '^[[:space:]]*func[[:space:]]+_(ready|process|physics_process|enter_tree)[[:space:]]*\(' "$file" || continue
  checked_files=$((checked_files + 1))

  report=$(awk -v props="$SERIALISED_PROPS" -v guard_window="$GUARD_WINDOW" '
    function strip_comment(s,   q) {
      # Only strip a trailing comment when the line has no quote character, so a "#" inside a
      # string literal is never mistaken for a comment start.
      if (s ~ /["'"'"']/) return s
      sub(/#.*/, "", s)
      return s
    }
    function code_of(s) {
      s = strip_comment(s)
      sub(/^[[:space:]]+/, "", s)
      sub(/[[:space:]]+$/, "", s)
      return s
    }
    {
      raw[NR] = $0
      code[NR] = code_of($0)
    }
    END {
      # ---- pass 1: identifiers this file constructs at run time ---------------
      for (i = 1; i <= NR; i++) {
        line = code[i]
        if (match(line, /^(var[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*([[:space:]]*:[[:space:]]*[A-Za-z0-9_.]+)?[[:space:]]*:?=[[:space:]]*[A-Za-z0-9_.]+\.new\(/)) {
          name = line
          sub(/^var[[:space:]]+/, "", name)
          sub(/[^A-Za-z0-9_].*$/, "", name)
          if (name != "") constructed[name] = 1
        }
      }

      # ---- pass 2: serialised-property writes on receivers we did not build ---
      writes = 0
      write_report = ""
      for (i = 1; i <= NR; i++) {
        line = code[i]
        if (line == "") continue
        # NOTE: character classes, not \b — BSD/macOS awk treats \b as a backspace escape, not a
        # word boundary (verified: `awk BEGIN{ if ("if x" ~ /^if\b/) ... }` does not match here).
        if (line ~ /^(var|const|@export|signal|func|class_name|extends)([^A-Za-z0-9_]|$)/) continue
        hit = ""
        if (match(line, "(^|[^A-Za-z0-9_.\"])([A-Za-z_][A-Za-z0-9_]*\\.)?(" props ")[[:space:]]*=[^=]")) {
          hit = substr(line, RSTART, RLENGTH)
        } else if (match(line, /(^|[^A-Za-z0-9_."])([A-Za-z_][A-Za-z0-9_]*\.)?add_theme_[a-z_]+_override[[:space:]]*\(/)) {
          hit = substr(line, RSTART, RLENGTH)
        }
        if (hit == "") continue
        recv = hit
        if (match(recv, /[A-Za-z_][A-Za-z0-9_]*\./)) {
          recv = substr(recv, RSTART, RLENGTH - 1)
        } else {
          recv = ""
        }
        if (recv != "" && (recv in constructed)) continue
        writes++
        if (writes <= 3) write_report = write_report sprintf("      writes serialised state at line %d: %s\n", i, line)
      }
      if (writes == 0) exit 0

      # ---- pass 3: unguarded lifecycle callbacks ------------------------------
      unguarded = ""
      for (i = 1; i <= NR; i++) {
        if (raw[i] !~ /^[[:space:]]*func[[:space:]]+_(ready|process|physics_process|enter_tree)[[:space:]]*\(/) continue
        fname = raw[i]
        sub(/^[[:space:]]*func[[:space:]]+/, "", fname)
        sub(/[[:space:]]*\(.*$/, "", fname)
        seen = 0
        guarded = 0
        guard_at = 0
        for (j = i + 1; j <= NR; j++) {
          if (raw[j] ~ /^[^[:space:]]/ && code[j] != "") break     # next top-level declaration
          if (code[j] == "") continue
          seen++
          if (guard_at == 0 && seen > guard_window) break
          if (guard_at == 0 && code[j] ~ /Engine\.is_editor_hint\(\)/ && code[j] ~ /^if[^A-Za-z0-9_]/) {
            guard_at = seen
            if (code[j] ~ /:[[:space:]]*return/) { guarded = 1; break }
            continue
          }
          if (guard_at > 0) {
            if (code[j] ~ /^return([^A-Za-z0-9_]|$)/) { guarded = 1; break }
            if (seen - guard_at > 4) break
          }
        }
        if (!guarded) unguarded = unguarded sprintf("      unguarded lifecycle callback: %s (line %d)\n", fname, i)
      }
      if (unguarded == "") exit 0
      printf "%s%s", unguarded, write_report
      exit 1
    }
  ' "$file") && continue

  violations="${violations}  ${file}
${report}
"
done < <(find "$SCAN_DIR" -name '*.gd' -type f | sort)

if [ -n "$violations" ]; then
  echo "FAIL: @tool script(s) can write serialised scene state while running in the editor."
  echo "Fix: make the lifecycle callback return early —"
  echo "     if Engine.is_editor_hint():"
  echo "         return"
  echo "or move the write off the editor path. If editor execution is correct for this file, add it"
  echo "to ALLOWLIST_RAW in scripts/check_tool_safety.sh with a '#' comment saying why."
  echo ""
  printf '%s' "$violations"
  echo "check_tool_safety: FAIL"
  exit 1
fi

echo "check_tool_safety: OK ($scanned_gd .gd scanned, $tool_files @tool files, $checked_files with lifecycle callbacks analysed, ${#allowlist[@]} allowlisted)"
