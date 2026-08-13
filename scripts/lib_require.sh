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
    # The remedy names the tool that is actually missing. This line used to read "(apt: ripgrep)"
    # unconditionally, because rg was the only caller when it was written; editor_scan.sh now requires
    # godot, and being told to apt-install ripgrep when Godot is what is absent sends the reader the
    # wrong way. A gate's error message is read exactly once, at the worst moment, so it has to be right.
    echo "       Refusing to report a pass on zero files. Install '$tool' and re-run." >&2
    exit 2
  fi
}

# A gate's SCOPE is as load-bearing as its rule, and it is usually implicit. check_shaders_compile walked
# every .glsl under addons/ and so read 10 files in a worktree (where bin/ is a symlink) and 58 in the
# primary checkout, where whisper.cpp's vendored ggml-vulkan sources appear: green in one tree and red in
# the other, from the same commit. The count a gate examines is part of its verdict. Assert it.
#
#   require_scanned <examined> <floor> <what>
#
# Exits 2, not 1: a scope that collapsed is a gate that could not run, not a violation it found.
require_scanned() {
  local have="${1:-0}" floor="$2" what="$3"
  local caller="${BASH_SOURCE[1]:-gate}"
  if [ "$have" -lt "$floor" ]; then
    echo "ERROR: ${caller##*/} examined $have $what, below its floor of $floor." >&2
    echo "       Its scope collapsed. A shrunken gate reports a pass it never earned." >&2
    exit 2
  fi
}
