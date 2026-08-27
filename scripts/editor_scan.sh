#!/usr/bin/env bash
# =====================================================================================================
# EDITOR SCAN — register class_name / .gdextension SERIALLY, then PROVE the tree actually parses.
#
# THE LOCK. A full `godot --headless --editor` loads every GDExtension, including the zylann.voxel editor
# build, which spins worker threads to import and generate. Two of those against the SAME .godot/ race and
# segfault. The scan is also the one thing every agent must run, so this wrapper takes a lock and
# concurrent callers queue.
#
# TWO PHASES, because an editor scan does not parse your code. Its log is twenty progress-bar lines and
# says nothing about any script: "Loading global class names" reads only `class_name` and `extends` and
# never compiles a function body. A script the editor never LOADS cannot report a parse error, so a grep
# for error patterns is the ABSENCE of a pattern from a log that never carries one — a gate that can only
# pass. Phase 1 runs the editor, which is what registers a new class_name / .gdextension and imports, and
# demands positive evidence it ran. Phase 2 force-LOADS every .gd under the addon through
# scripts/parse_all_scripts.gd, because loading is what makes the engine parse a file, and fails on any
# parse diagnostic.
#
#   scripts/editor_scan.sh                # scan + parse sweep, print the verdict, non-zero if any
#   scripts/editor_scan.sh --quiet        # the error count and nothing else
#   scripts/editor_scan.sh --path <dir>   # scan a different project (staged copies, worktrees)
#
# EXIT CODES.  0 = clean.  1 = the tree has errors.  2 = the gate COULD NOT RUN (missing tool, lock
# timeout, no evidence the editor executed, no verdict from the sweep, or zero scripts examined). 2 is
# distinct on purpose: this repo has already shipped gates that reported a pass while examining zero
# files. A gate that cannot run must fail, never pass.
# =====================================================================================================
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_godot.sh"

# Pure-bash, no `dirname`: this must still resolve when PATH is broken, or the missing-tool check below
# never gets a chance to report exit 2.
ROOT="$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)"
# shellcheck source=lib_require.sh
source "$ROOT/scripts/lib_require.sh"

GODOT="${GODOT:-godot}"
PROJECT="$ROOT"
QUIET=0
QUIT_AFTER="${LA_SCAN_QUIT_AFTER:-400}"
# Long enough for a queue of agents, short enough to fail loudly rather than hang a CI job.
LOCK_TIMEOUT="${LA_SCAN_LOCK_TIMEOUT:-600}"
# Phase 2 lives in its own gate so lint can run it without taking the editor lock. See its header.
PARSE_GATE="$ROOT/scripts/check_parse_all.sh"
# Any one of these in the EDITOR log means a class failed to register. Kept identical to the parse gate's
# grep so the two cannot drift into disagreeing about what an error looks like.
ERR_PATTERN='parse error|script error|failed to load|could not resolve class'

while [[ $# -gt 0 ]]; do
  case "$1" in
    --quiet) QUIET=1; shift ;;
    --path) PROJECT="$2"; shift 2 ;;
    --quit-after) QUIT_AFTER="$2"; shift 2 ;;
    *) echo "editor_scan: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

require_tool "$GODOT"
if [[ ! -x "$PARSE_GATE" ]]; then
  echo "editor_scan: cannot execute its parse gate at $PARSE_GATE." >&2
  echo "             Half this check is missing, so it fails rather than reporting on the other half." >&2
  exit 2
fi
if [[ ! -f "$PROJECT/project.godot" ]]; then
  echo "editor_scan: no project.godot under '$PROJECT' — there is nothing here to scan." >&2
  exit 2
fi

# mkdir is atomic on every filesystem we care about, so it is the portable lock primitive here (macOS has
# no flock(1)). MACHINE-WIDE, and shared with scripts/godot_import.sh: a per-project lock excluded nothing
# once every lane ran in its own worktree, and what races is the shared GDExtension load.
LOCK_DIR="${TMPDIR:-/tmp}/la_godot_extension.lock"
mkdir -p "${PROJECT}/.godot" 2>/dev/null || true

waited=0
until mkdir "$LOCK_DIR" 2>/dev/null; do
  # Reclaim a lock whose owner died (a crashed or killed scan must not block everyone forever).
  if [[ -f "$LOCK_DIR/pid" ]]; then
    owner="$(cat "$LOCK_DIR/pid" 2>/dev/null || echo "")"
    if [[ -n "$owner" ]] && ! kill -0 "$owner" 2>/dev/null; then
      echo "editor_scan: clearing stale lock from dead pid $owner" >&2
      rm -rf "$LOCK_DIR"
      continue
    fi
  fi
  if (( waited >= LOCK_TIMEOUT )); then
    echo "editor_scan: timed out after ${LOCK_TIMEOUT}s waiting for $LOCK_DIR" >&2
    exit 2
  fi
  sleep 2
  waited=$(( waited + 2 ))
done
echo $$ > "$LOCK_DIR/pid"

LOG="$(mktemp)"
PARSE_LOG="$(mktemp)"
trap 'rm -rf "$LOCK_DIR"; rm -f "$LOG" "$PARSE_LOG"' EXIT

# --- phase 1: the editor scan (class_name + .gdextension registration, import) ------------------------
scan_rc=0
la_godot --headless --editor --quit-after "$QUIT_AFTER" --path "$PROJECT" > "$LOG" 2>&1 || scan_rc=$?

# Positive evidence that the editor actually ran. Every Godot invocation prints its banner; an empty or
# bannerless log means the binary never got going, and the old `|| true` turned exactly that into a pass.
if ! grep -qa 'Godot Engine v' "$LOG"; then
  echo "editor_scan: the editor produced no Godot banner (exit $scan_rc), so it never ran." >&2
  echo "             Refusing to report a clean scan on a log that proves nothing. Last 20 lines:" >&2
  tail -n 20 "$LOG" | sed 's/^/    /' >&2
  exit 2
fi
if [[ "$scan_rc" -ne 0 ]]; then
  echo "editor_scan: the editor exited $scan_rc. A crashed scan is not a clean scan. Last 20 lines:" >&2
  tail -n 20 "$LOG" | sed 's/^/    /' >&2
  exit 2
fi

editor_errors="$(grep -ciaE "$ERR_PATTERN" "$LOG" || true)"
editor_errors="${editor_errors:-0}"

# --- phase 2: force-load every script, which is what makes the engine parse it ------------------------
# Delegated to scripts/check_parse_all.sh so there is ONE implementation of "does this tree parse" rather
# than a copy here and a copy in the lint pipeline that drift apart. It prints its own diagnosis; this
# reads the PARSE_GATE= summary for the counts.
parse_rc=0
"$PARSE_GATE" --path "$PROJECT" --quiet > "$PARSE_LOG" 2>&1 || parse_rc=$?

parse_line="$(grep -a '^PARSE_GATE=' "$PARSE_LOG" | tail -n 1 || true)"
if [[ "$parse_rc" -eq 2 || -z "$parse_line" ]]; then
  echo "editor_scan: the parse gate could not run (exit $parse_rc), so half this scan verified nothing:" >&2
  cat "$PARSE_LOG" | tail -n 20 | sed 's/^/    /' >&2
  exit 2
fi
checked="$(printf '%s' "$parse_line" | grep -oE '"checked":[0-9]+' | grep -oE '[0-9]+$' || true)"
parse_err_count="$(printf '%s' "$parse_line" | grep -oE '"errors":[0-9]+' | grep -oE '[0-9]+$' || true)"
failed="$(printf '%s' "$parse_line" | grep -oE '"null":[0-9]+' | grep -oE '[0-9]+$' || true)"
if [[ -z "${checked:-}" || -z "${parse_err_count:-}" || -z "${failed:-}" || "$checked" -le 0 ]]; then
  echo "editor_scan: unreadable parse verdict '$parse_line'. Refusing to report a clean scan." >&2
  exit 2
fi

total=$(( editor_errors + parse_err_count + failed ))

# --- verdict ------------------------------------------------------------------------------------------
if [[ "$QUIET" -eq 1 ]]; then
  echo "$total"
  if [[ "$total" -eq 0 ]]; then exit 0; fi
  exit 1
fi

if [[ "$total" -eq 0 ]]; then
  echo "editor_scan: OK (editor scan clean; $checked scripts force-loaded, 0 parse errors)"
  exit 0
fi

if [[ "$editor_errors" -gt 0 ]]; then
  echo "editor_scan: $editor_errors error line(s) from the editor scan (class / .gdextension registration):"
  grep -inaE "$ERR_PATTERN" "$LOG" | head -40 | sed 's/^/    /'
  echo
  echo "A class that does not register is MISSING at run time. Fix this before trusting the tree."
fi
# The parse gate has already explained itself; passing its own words through unindented keeps one voice
# instead of wrapping its paragraph inside a near-identical one of ours.
if [[ "$parse_err_count" -gt 0 || "$failed" -gt 0 ]]; then
  grep -av '^PARSE_GATE=' "$PARSE_LOG" | head -40
fi
exit 1
