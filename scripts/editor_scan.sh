#!/usr/bin/env bash
# =====================================================================================================
# EDITOR SCAN — register class_name / .gdextension SERIALLY, then PROVE the tree actually parses.
#
# WHY THE LOCK. A full `godot --headless --editor` run loads every GDExtension, including the
# zylann.voxel editor build, which spins worker threads to import and generate. Two of those running at
# once against the SAME .godot/ directory race and segfault — measured 2026-07-28, six Godot crashes in
# three minutes with faulting frames inside libvoxel.macos.editor.universal on a thread named "run",
# while ten parallel agents each ran the scan a handful of times.
#
# The scan is also the ONE thing every agent wants to run (a new class_name does not register without
# it), so "just do not run it concurrently" is not a rule anyone can follow by hand. This wrapper takes a
# lock instead: concurrent callers queue and each gets a correct scan.
#
# -----------------------------------------------------------------------------------------------------
# WHY THERE IS A SECOND PHASE, measured 2026-08-09.
#
# This gate used to be one editor run plus a grep of its log for
# `parse error|script error|failed to load|could not resolve class`. It printed `editor_scan: OK (0
# errors)` on a tree where sim/material/sphere_passes/WaterSlumpLavaPass.gd had a hard parse error
# (`Identifier "ctx" not declared in the current scope`). The simulation then ran to completion and exited
# 0 with a full SIM_REPORT at the same field_step 590 a healthy run reaches. Measured, broken vs healthy,
# 600 frames at seed 4242: temp_ground_p50 15.0 (exactly INITIAL_TEMP) vs 26.196 · snow_cells 0 vs 1147 ·
# sediment_total 0.0 vs 601.75 · erosion_cells 0 vs 1348. Three mass-transport CAs silently absent, and
# nothing in the output said so.
#
# THE GREP WAS NOT TOO NARROW. THE LOG CONTAINED NOTHING TO GREP. A full editor scan of this project
# emits twenty lines, every one of them a progress bar, and not one word about any script:
#     [  16% ] first_scan_filesystem | Loading global class names...
#     [  83% ] first_scan_filesystem | Starting file scan...
#     [ DONE ] first_scan_filesystem
# "Loading global class names" reads only enough of each .gd to pull out `class_name` and `extends`; it
# never compiles a function body. A script the editor never LOADS cannot report a parse error, and nothing
# loads WaterSlumpLavaPass.gd at scan time: it declares no class_name and is reached at run time through a
# res:// string in MaterialSphereGPU3D.gd's pass list. So the old pass condition was the ABSENCE of a
# pattern from a log that never carries it — a gate that could only ever pass.
#
# It also passed when Godot was not installed. The invocation ended in `|| true`, so a missing binary, a
# wrong --path, or a segfault all produced an empty log, which greps to zero, which printed OK.
#
# So phase 1 still runs the editor — that is what registers a new class_name / .gdextension and imports —
# and now demands positive evidence that it ran. Phase 2 force-LOADS every .gd under the addon in one
# headless process via scripts/parse_all_scripts.gd, because loading is what makes the engine parse a
# file, and fails on any parse diagnostic.
#
# That machinery already existed. It was wired into scripts/check_library_only.sh only, which runs under
# `agent_harness.sh lint` and stages a tree with game/ DELETED — so game/ was force-parsed by nothing at
# all (263 scripts checked there against 317 here). GODOT_BEST_PRACTICES.md has said "a scan is necessary
# and not sufficient, also run check_library_only.sh" since 2026-07-29; asking every agent to remember a
# second command is the same rule-nobody-can-follow-by-hand that the lock above exists to replace. The
# scan does it itself now.
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
"$GODOT" --headless --editor --quit-after "$QUIT_AFTER" --path "$PROJECT" > "$LOG" 2>&1 || scan_rc=$?

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
