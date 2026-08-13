#!/usr/bin/env bash
# =====================================================================================================
# SHADER-COMPILE GATE — every compute kernel actually compiles, checked without a GPU.
#
# WHY THIS EXISTS. A broken `.glsl` in this project is SILENT. `godot --headless --import` accepts a
# kernel containing an undeclared symbol without a word of complaint (verified 2026-08-10: an import of a
# probe kernel referencing `this_symbol_does_not_exist` reported success). The failure surfaces only at
# runtime, as `get_spirv on a null value`, and what the maintainer sees is a sim that runs to completion
# and prints a full, normal-looking SIM_REPORT with one entire pass silently not running. CLAUDE.md
# records exactly that happening in a fresh worktree — `biomass` 0, every number in the report fiction.
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

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib_require.sh
source "$REPO_ROOT/scripts/lib_require.sh" 2>/dev/null || true
if declare -f require_tool >/dev/null 2>&1; then
  require_tool godot
elif ! command -v godot >/dev/null 2>&1; then
  echo "ERROR: godot not on PATH — a gate that cannot run FAILS, it does not pass." >&2
  exit 2
fi

PROBE_REL="addons/local_agents/tests/tmp_check_shaders_compile.gd"
PROBE="$REPO_ROOT/$PROBE_REL"
cleanup() { rm -f "$PROBE" "$PROBE.uid"; }
trap cleanup EXIT

cat > "$PROBE" <<'GD'
extends SceneTree

const ROOT: String = "res://addons/local_agents"

# Every stage a .glsl in this tree could declare. A kernel is compute; the others are here so a future
# raster shader cannot slip through unchecked.
const STAGES: Array = [
	RenderingDevice.SHADER_STAGE_COMPUTE,
	RenderingDevice.SHADER_STAGE_VERTEX,
	RenderingDevice.SHADER_STAGE_FRAGMENT,
]

func _find(dir_path: String, out: Array) -> void:
	var d: DirAccess = DirAccess.open(dir_path)
	if d == null:
		return
	d.list_dir_begin()
	var name: String = d.get_next()
	while name != "":
		if name.begins_with("."):
			name = d.get_next()
			continue
		var full: String = dir_path.path_join(name)
		if d.current_is_dir():
			# Vendored GLSL is not ours and is not a Godot kernel: whisper.cpp ships ggml-vulkan
			# sources Godot never imports, so get_spirv() is null for all of them by construction.
			if name != "thirdparty":
				_find(full, out)
		elif name.ends_with(".glsl"):
			out.append(full)
		name = d.get_next()
	d.list_dir_end()

func _init() -> void:
	var files: Array = []
	_find(ROOT, files)
	files.sort()
	var failed: int = 0
	for path in files:
		var sf = load(path)
		if sf == null:
			# Almost always an UNIMPORTED kernel — the fresh-worktree trap. load() returns null, the pass
			# silently never runs, and the report still looks normal.
			print("SHADER_FAIL={\"file\":\"%s\",\"why\":\"load() returned null (unimported?)\"}" % path)
			failed += 1
			continue
		if not sf.has_method("get_spirv"):
			print("SHADER_FAIL={\"file\":\"%s\",\"why\":\"not an RDShaderFile\"}" % path)
			failed += 1
			continue
		var spirv = sf.get_spirv()
		if spirv == null:
			print("SHADER_FAIL={\"file\":\"%s\",\"why\":\"get_spirv() returned null\"}" % path)
			failed += 1
			continue
		var bad: bool = false
		for stage in STAGES:
			var err: String = spirv.get_stage_compile_error(stage)
			if err != "":
				var first: String = err.split("\n")[0]
				print("SHADER_FAIL={\"file\":\"%s\",\"stage\":%d,\"why\":%s}" % [path, stage, JSON.stringify(first)])
				bad = true
		if bad:
			failed += 1
	print("SHADER_GATE={\"checked\":%d,\"failed\":%d}" % [files.size(), failed])
	quit(1 if failed > 0 else 0)
GD

# THE CACHE IS NOT INVALIDATED BY AN INCLUDE. Editing a .glsli leaves every .glsl that includes it holding
# its old SPIR-V in .godot/imported, and `--import` does not notice — not even after touching the .glsl.
# `load()` then returns the STALE kernel and this gate reads green against code that no longer exists.
# Verified by zeroing a latent heat in enthalpy.glsli: the GPU kept the old value until the cache was
# deleted. Drop the kernels' cache entries and re-import so every probe below compiles from source.
if [ -d "$REPO_ROOT/.godot/imported" ]; then
  find "$REPO_ROOT/.godot/imported" -maxdepth 1 -name '*.glsl-*' -delete
  (cd "$REPO_ROOT" && timeout 300 godot --headless --path . --import >/dev/null 2>&1) || true
fi

out="$(cd "$REPO_ROOT" && timeout 300 godot --headless --path . -s "res://$PROBE_REL" 2>&1)"
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
require_scanned "$checked_n" "${SHADER_FLOOR:-10}" "first-party .glsl kernels"
if echo "$out" | grep -q '"failed":0'; then
  echo "check_shaders_compile: OK (every .glsl loads and compiles; no GPU required)"
  exit 0
fi
echo
echo "A kernel that does not compile does NOT stop the sim. It loads as null, its pass silently does not"
echo "run, and the report still prints a full set of plausible numbers. Fix it before believing any of them."
exit 1
