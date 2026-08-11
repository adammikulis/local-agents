#!/usr/bin/env bash
# =====================================================================================================
# PARSE GATE — force every script in the tree to LOAD, because loading is what makes the engine parse it.
#
# WHY THIS EXISTS, measured 2026-08-09. An editor scan does not parse your code. `godot --headless
# --editor` emits twenty progress lines and nothing about any script: its "Loading global class names"
# step reads just enough of each .gd to pull out `class_name` and `extends`, and never compiles a
# function body. So a script the editor never LOADS cannot report a parse error, and a script reached at
# run time through a res:// string — every sphere_passes/ plugin, for one — is never loaded at scan time.
#
# sim/material/sphere_passes/WaterSlumpLavaPass.gd was broken on purpose to measure this. The editor scan
# printed `OK (0 errors)`, and the simulation then ran to completion and exited 0. Both runs, 600 frames,
# seed 4242, --fast=8, reaching the SAME field_step 590 — broken against healthy:
#     temp_ground_p50   15.0 (exactly INITIAL_TEMP)  vs  26.196
#     snow_cells        0                            vs  1147
#     sediment_total    0.0                          vs  601.75
#     erosion_cells     0                            vs  1348
#     temp_mean         17.26                        vs  34.91
#     h2o_total         2743.4                       vs  4384.6
# Three whole mass-transport CAs were gone and the report still looked like a report. A tree that does not
# parse still produces numbers, and nothing in the output says they are fiction. That is the whole danger.
#
# The sweep itself is scripts/parse_all_scripts.gd, which load()s every .gd under a root in ONE headless
# process. It already existed and was wired into check_library_only.sh alone — which stages a tree with
# game/ DELETED, so it covers 263 scripts and game/ was force-parsed by nothing at all. This gate runs the
# same sweep against the REAL project: 317 scripts, game/ included. Measured with the compiled
# GDExtension absent as well, since CI has no built binary: still 317 checked, zero error lines.
#
#   scripts/check_parse_all.sh                # sweep the repo
#   scripts/check_parse_all.sh --path <dir>   # sweep a staged copy or a worktree
#   scripts/check_parse_all.sh --quiet        # just the PARSE_GATE= summary line
#
# Prints PARSE_GATE={"checked":N,"errors":N,"null":N} as its last line so a caller can read the counts
# rather than re-deriving them (scripts/editor_scan.sh does exactly that).
#
# EXIT CODES.  0 = every script parses.  1 = at least one does not.  2 = the gate COULD NOT RUN (missing
# godot, missing sweep script, no project, no verdict, or zero scripts examined). 2 is distinct on
# purpose: a gate that cannot run must fail, never pass.
# =====================================================================================================
set -uo pipefail

# Pure-bash, no `dirname`: this must still resolve when PATH is broken, or the missing-tool check below
# never gets a chance to report exit 2.
SCRIPT_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
# shellcheck source=lib_require.sh
source "$SCRIPT_DIR/lib_require.sh"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

GODOT="${GODOT:-godot}"
PROJECT="$ROOT"
QUIET=0
# Everything first-party the runtime ships lives under here. zylann.voxel is third party and outside it.
PARSE_ROOT="res://addons/local_agents"
SWEEP="$SCRIPT_DIR/parse_all_scripts.gd"
# Kept identical to check_library_only.sh's grep so the two gates cannot drift into disagreeing about
# what a parse failure looks like.
ERR_PATTERN='parse error|script error|failed to load|could not resolve class'

while [[ $# -gt 0 ]]; do
  case "$1" in
    --quiet) QUIET=1; shift ;;
    --path) PROJECT="$2"; shift 2 ;;
    *) echo "check_parse_all: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

require_tool "$GODOT"
if [[ ! -f "$SWEEP" ]]; then
  echo "ERROR: check_parse_all.sh cannot find its sweep at $SWEEP." >&2
  echo "       Refusing to report a pass on zero files." >&2
  exit 2
fi
if [[ ! -f "$PROJECT/project.godot" ]]; then
  echo "ERROR: check_parse_all.sh found no project.godot under '$PROJECT'." >&2
  exit 2
fi

LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT

"$GODOT" --headless --path "$PROJECT" -s "$SWEEP" -- "--root=$PARSE_ROOT" > "$LOG" 2>&1
sweep_rc=$?

verdict="$(grep -a '^PARSE_ALL=' "$LOG" | tail -n 1)"
if [[ -z "$verdict" ]]; then
  echo "ERROR: the sweep produced no PARSE_ALL verdict (exit $sweep_rc), so nothing was checked." >&2
  tail -n 20 "$LOG" | sed 's/^/    /' >&2
  exit 2
fi

checked="$(printf '%s' "$verdict" | grep -oE '"checked":[0-9]+' | grep -oE '[0-9]+$')"
nulls="$(printf '%s' "$verdict" | grep -oE '"failed":[0-9]+' | grep -oE '[0-9]+$')"
if [[ -z "${checked:-}" || -z "${nulls:-}" || "$checked" -le 0 ]]; then
  echo "ERROR: the sweep examined ${checked:-no} script(s) under $PARSE_ROOT of '$PROJECT'." >&2
  echo "       Refusing to report a pass on zero files. Verdict was: $verdict" >&2
  exit 2
fi

# The sweep's null count is NOT sufficient on its own, and neither is its exit code: load() on a script
# with a parse error prints the diagnostic and still hands back a non-null Script, so `failed` stays 0 for
# the exact failure this gate exists to catch (measured: the WaterSlumpLavaPass break came back as
# PARSE_ALL={"checked":317,"failed":0}). Loading provokes the error; this grep notices it. Both required.
errs="$(grep -aiE "$ERR_PATTERN" "$LOG")"
err_count=0
if [[ -n "$errs" ]]; then
  err_count="$(printf '%s\n' "$errs" | grep -c .)"
fi

if [[ "$err_count" -gt 0 || "$nulls" -gt 0 ]]; then
  echo "check_parse_all: FAIL — these do not parse ($checked scripts swept, $nulls returned null):"
  printf '%s\n' "$errs" | head -40 | sed 's/^/    /'
  echo
  echo "A script that does not parse still lets the sim run and print a full SIM_REPORT, with whatever"
  echo "that script does silently missing. Fix the parse error before trusting any number from this tree."
  echo "PARSE_GATE={\"checked\":$checked,\"errors\":$err_count,\"null\":$nulls}"
  exit 1
fi

if [[ "$QUIET" -eq 0 ]]; then
  echo "check_parse_all: OK ($checked scripts force-loaded from $PARSE_ROOT, 0 parse errors)"
fi
echo "PARSE_GATE={\"checked\":$checked,\"errors\":0,\"null\":0}"
exit 0
