#!/usr/bin/env bash
# Headless export of the LocalAgents itch.io native (downloadable) build.
#
# Usage:
#   scripts/export_game.sh <platform> [output-path]
#
#   <platform>   macos | windows | linux   (or the full preset name, e.g. "Linux/X11")
#   output-path  optional override for the export output (defaults per platform under build/)
#
# What it does:
#   godot --headless --export-release "<preset name>" <output path>
#   ...after creating the output directory. Presets live in export_presets.cfg.
#
# The LLM model is NOT bundled — the exported build boots to the MainMenu and the
# player downloads a model in-game on first run (see runtime/RuntimePaths.gd).
#
# Cross-platform bin reality: the native GDExtension library + its runtime dep libs
# (libllama/libggml*/libmtmd, listed in the .gdextension [dependencies] section) live
# under addons/local_agents/gdextensions/localagents/bin/ and Godot copies them next to
# the app binary on export. Only the macOS .dylib set is produced on the dev host. Before
# exporting Windows or Linux you MUST drop that platform's localagents.<platform>.{dll,so}
# plus its runtime dep libs into the bin dir, taken from the CI build-extension.yml
# artifacts (localagents-windows-bin / localagents-linux-bin). See docs/EXPORT.md.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

if [ "$#" -lt 1 ]; then
  echo "usage: scripts/export_game.sh <macos|windows|linux> [output-path]" >&2
  exit 2
fi

GODOT_BIN="${GODOT_BIN:-godot}"
PLATFORM_ARG="$1"
OUT_OVERRIDE="${2:-}"

case "${PLATFORM_ARG}" in
  macos|macOS|osx)      PRESET="macOS";           DEFAULT_OUT="build/macos/LocalAgents.app" ;;
  windows|win)          PRESET="Windows Desktop"; DEFAULT_OUT="build/windows/LocalAgents.exe" ;;
  linux|linux/x11)      PRESET="Linux/X11";       DEFAULT_OUT="build/linux/LocalAgents.x86_64" ;;
  *)                    PRESET="${PLATFORM_ARG}";  DEFAULT_OUT="build/other/LocalAgents" ;;
esac

OUT_PATH="${OUT_OVERRIDE:-${DEFAULT_OUT}}"
mkdir -p "$(dirname "${OUT_PATH}")"

BIN_DIR="addons/local_agents/gdextensions/localagents/bin"
if [ ! -e "${BIN_DIR}/localagents.macos.dylib" ] \
   && [ ! -e "${BIN_DIR}/localagents.windows.dll" ] \
   && [ ! -e "${BIN_DIR}/localagents.linux.so" ]; then
  echo "WARNING: no native GDExtension libraries found under ${BIN_DIR}." >&2
  echo "         The export will produce a build that cannot load the extension." >&2
  echo "         Build/symlink the bin dir first (see docs/EXPORT.md)." >&2
fi

echo "Exporting preset '${PRESET}' -> ${OUT_PATH}"
"${GODOT_BIN}" --headless --export-release "${PRESET}" "${OUT_PATH}" --path "${REPO_ROOT}"
echo "Done: ${OUT_PATH}"
