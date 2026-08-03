#!/usr/bin/env bash
# Shared preflight for the gate scripts. Source it, then call `require_tool rg` for anything the gate
# cannot do its job without.
#
# WHY THIS EXISTS, measured 2026-07-29. ripgrep is not installed on the GitHub Actions runner, and it was
# never in the workflow's apt list. `check_max_file_length.sh` built its file list with `rg --files`, got
# "rg: command not found" three times, ended up with an empty list, printed "No matching files found for
# max-file-length check." and exited 0. `check_no_direct_refcounted_invocation.sh` wrapped its `rg` in
# `|| true`, got an empty result, and printed "check passed". Both gates reported success in CI while
# examining ZERO files, on every push for months. Two files were over the limit CI claimed to enforce the
# whole time.
#
# A missing tool must never read as a pass. Exit code 2 (distinct from a real violation's 1) so a caller
# can tell "the gate could not run" from "the gate found something".
require_tool() {
  local tool="$1"
  if ! command -v "$tool" >/dev/null 2>&1; then
    # Pure-bash basename. A broken PATH is one of the ways a gate loses its tools, so the message that
    # explains it must not itself depend on an external binary — `basename` printed "command not found"
    # and left the gate name blank in exactly that case.
    local caller="${BASH_SOURCE[1]:-gate}"
    echo "ERROR: ${caller##*/} requires '$tool' and it is not installed." >&2
    echo "       Refusing to report a pass on zero files. Install it (apt: ripgrep) and re-run." >&2
    exit 2
  fi
}
