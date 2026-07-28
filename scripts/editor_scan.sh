#!/usr/bin/env bash
# Run Godot's editor scan (class_name / .gdextension registration + import) SERIALLY.
#
# Why this exists: a full `godot --headless --editor` run loads every GDExtension, including the
# zylann.voxel editor build, which spins worker threads to import and generate. Two of those running
# at once against the SAME .godot/ directory race and segfault — measured 2026-07-28, six Godot
# crashes in three minutes with faulting frames inside libvoxel.macos.editor.universal on a thread
# named "run", while ten parallel agents each ran the scan a handful of times.
#
# The scan is also the ONE thing every agent wants to run (a new class_name does not register without
# it), so "just do not run it concurrently" is not a rule anyone can follow by hand. This wrapper
# takes a lock instead: concurrent callers queue and each gets a correct scan.
#
#   scripts/editor_scan.sh                # scan, print the error count, exit non-zero if any
#   scripts/editor_scan.sh --quiet        # only the count
#   scripts/editor_scan.sh --path <dir>   # scan a different project (staged copies, worktrees)
#
# Exit: 0 when the scan found no parse/script/load errors, 1 when it did, 2 on lock timeout.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-godot}"
PROJECT="$ROOT"
QUIET=0
QUIT_AFTER="${LA_SCAN_QUIT_AFTER:-400}"
# Long enough for a queue of agents, short enough to fail loudly rather than hang a CI job.
LOCK_TIMEOUT="${LA_SCAN_LOCK_TIMEOUT:-600}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --quiet) QUIET=1; shift ;;
    --path) PROJECT="$2"; shift 2 ;;
    --quit-after) QUIT_AFTER="$2"; shift 2 ;;
    *) echo "editor_scan: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

# mkdir is atomic on every filesystem we care about, so it is the portable lock primitive here
# (macOS has no flock(1)). The lock lives beside the project it guards, because the race is over
# that project's .godot directory — two DIFFERENT projects may scan at the same time safely.
LOCK_DIR="${PROJECT}/.godot/.editor_scan.lock"
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
trap 'rm -rf "$LOCK_DIR"' EXIT

LOG="$(mktemp)"
trap 'rm -rf "$LOCK_DIR"; rm -f "$LOG"' EXIT
"$GODOT" --headless --editor --quit-after "$QUIT_AFTER" --path "$PROJECT" > "$LOG" 2>&1 || true

errors="$(grep -ciE 'parse error|script error|failed to load|could not resolve class' "$LOG" || true)"
errors="${errors:-0}"

if [[ "$QUIET" -eq 1 ]]; then
  echo "$errors"
else
  if [[ "$errors" -eq 0 ]]; then
    echo "editor_scan: OK (0 errors)"
  else
    echo "editor_scan: $errors error line(s):"
    grep -inE 'parse error|script error|failed to load|could not resolve class' "$LOG" | head -40 | sed 's/^/    /'
  fi
fi

[[ "$errors" -eq 0 ]]
