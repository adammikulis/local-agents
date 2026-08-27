#!/usr/bin/env bash
# PARSE GATE — force every script in the tree to LOAD, because loading is what makes the engine parse it.

# An editor scan does not parse your code. `godot --headless --editor` emits progress lines and nothing
# about any script: "Loading global class names" reads only enough of each .gd for `class_name` and
# `extends`, and never compiles a function body. A script the editor never LOADS cannot report a parse
# error, and one reached at run time through a res:// string — every sphere_passes/ plugin — is never
# loaded at scan time. A tree that does not parse still produces a full report, and nothing in the
# output says the numbers are fiction.

# The sweep is scripts/parse_all_scripts.gd, which load()s every .gd under a root in one headless
# process. check_library_only.sh runs it against a staged tree with game/ DELETED; this gate runs it
# against the REAL project, game/ included, and does not need the compiled GDExtension present.

#   scripts/check_parse_all.sh                # sweep the repo
#   scripts/check_parse_all.sh --path <dir>   # sweep a staged copy or a worktree
#   scripts/check_parse_all.sh --quiet        # just the PARSE_GATE= summary line

# Prints PARSE_GATE={"checked":N,"errors":N,"null":N} last so a caller reads the counts rather than
# re-deriving them; scripts/editor_scan.sh does exactly that.

# EXIT 0 every script parses · 1 at least one does not · 2 could not run (missing godot, missing sweep
# script, no project, no verdict, or zero scripts examined). A gate that cannot run must fail.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_godot.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_capture.sh"

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

if la_cap_dir >/dev/null && [ "$(cd "$PROJECT" && pwd)" = "$ROOT" ]; then
  la_headless parse_all > "$LOG" 2>&1
  sweep_rc=$?
  [ "$sweep_rc" -eq 0 ] || { echo "ERROR: the batch published no parse sweep." >&2; exit 2; }
else
  la_godot --headless --path "$PROJECT" -s "$SWEEP" -- "--root=$PARSE_ROOT" > "$LOG" 2>&1
  sweep_rc=$?
fi

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
