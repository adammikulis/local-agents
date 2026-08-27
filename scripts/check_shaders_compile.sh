#!/usr/bin/env bash
# =====================================================================================================
# SHADER-COMPILE GATE — every compute kernel actually compiles, checked without a GPU.
#
# WHY THIS EXISTS. A broken `.glsl` in this project is SILENT. `godot --headless --import` accepts a
# kernel containing an undeclared symbol without complaint. The failure surfaces only at runtime, as
# `get_spirv on a null value`, and the sim runs to completion and prints a full, normal-looking
# SIM_REPORT with one entire pass not running.
#
# The same class as check_parse_all.sh, for the half of the substrate that is not GDScript. Both exist
# because "it ran and printed numbers" is not evidence that the code ran.
#
# HOW, and the part that makes it cheap: `RDShaderFile.get_spirv()` returns an `RDShaderSPIRV` whose
# `get_stage_compile_error()` carries the compiler's message. Reading it needs NO RenderingDevice and no
# window, so this runs headless in about a second alongside every other gate.
#
# EXIT CODES. 0 pass · 1 a kernel failed to load or compile · 2 the gate could not run, never a silent pass.
# =====================================================================================================
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_godot.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_capture.sh"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib_require.sh
source "$REPO_ROOT/scripts/lib_require.sh" 2>/dev/null || true
if declare -f require_tool >/dev/null 2>&1; then
  require_tool godot
elif ! command -v godot >/dev/null 2>&1; then
  echo "ERROR: godot not on PATH — a gate that cannot run FAILS, it does not pass." >&2
  exit 2
fi

PROBE_REL="addons/local_agents/tests/gate_shaders_compile.gd"
[ -f "$REPO_ROOT/$PROBE_REL" ] || { echo "ERROR: MISSING $PROBE_REL." >&2; exit 2; }


# THE CACHE IS NOT INVALIDATED BY AN INCLUDE. Editing a .glsli leaves every .glsl that includes it holding
# its old SPIR-V in .godot/imported, and `--import` does not notice — not even after touching the .glsl.
# `load()` then returns the STALE kernel and this gate reads green against code that no longer exists.
# Verified by zeroing a latent heat in enthalpy.glsli: the GPU kept the old value until the cache was
# deleted. Drop the kernels' cache entries and re-import so every probe below compiles from source.
if la_cap_dir >/dev/null; then
  out="$(la_headless shaders_compile)" || exit 2
else
  if [ -d "$REPO_ROOT/.godot/imported" ]; then
    find "$REPO_ROOT/.godot/imported" -maxdepth 1 -name '*.glsl-*' -delete
    "$REPO_ROOT/scripts/godot_import.sh" "$REPO_ROOT" || true
  fi
  out="$(cd "$REPO_ROOT" && LA_GODOT_TIMEOUT=120 la_godot --headless --path . -s "res://$PROBE_REL" 2>&1)"
fi
echo "$out" | grep -E '^SHADER_FAIL=|^SHADER_GATE=' || true

if ! echo "$out" | grep -q '^SHADER_GATE='; then
  echo "ERROR: the shader probe produced no SHADER_GATE marker — it did not run to completion." >&2
  echo "$out" | tail -20 >&2
  exit 2
fi
if echo "$out" | grep -q '"checked":0'; then
  echo "ERROR: zero shaders found — refusing to report a pass on an empty comparison." >&2
  exit 2
fi
# Zero was never how this gate lost its scope. It read 10 here and 58 in the primary checkout from ONE
# commit, because a worktree's bin/ is a symlink and the vendored GLSL only exists on one side.
checked_n="$(echo "$out" | sed -nE 's/.*"checked":([0-9]+).*/\1/p' | tail -1)"
# The floor lives in docs/SHADER_FLOOR and the integrator writes it, so deleting a kernel does not require
# editing this gate. A number baked in here is one a lane must edit to do correct work.
FLOOR_FILE="$REPO_ROOT/docs/SHADER_FLOOR"
[ -f "$FLOOR_FILE" ] || { echo "check_shaders_compile: no docs/SHADER_FLOOR." >&2; exit 2; }
SHADER_FLOOR_N="$(rg -N -e '^[0-9]+$' "$FLOOR_FILE" 2>/dev/null | head -1)"
case "$SHADER_FLOOR_N" in
  "" | *[!0-9]*) echo "check_shaders_compile: docs/SHADER_FLOOR carries no number." >&2; exit 2 ;;
esac
require_scanned "$checked_n" "${SHADER_FLOOR:-$SHADER_FLOOR_N}" "first-party .glsl kernels"
if echo "$out" | grep -q '"failed":0'; then
  echo "check_shaders_compile: OK (every .glsl loads and compiles; no GPU required)"
  exit 0
fi
echo
echo "A kernel that does not compile does NOT stop the sim. It loads as null, its pass silently does not"
echo "run, and the report still prints a full set of plausible numbers. Fix it before believing any of them."
exit 1
