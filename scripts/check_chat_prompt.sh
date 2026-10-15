#!/usr/bin/env bash
# Render real llama.cpp templates without a model or an engine.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh"
require_tool c++
EXT="$ROOT/addons/local_agents/gdextensions/localagents"
KEY="$("$EXT/scripts/build_extension.sh" --print-deps-key)" || exit 2
DEPS="${LA_DEPS_CACHE:-$HOME/.cache/local-agents/extdeps}/$KEY"
[ -f "$DEPS/READY" ] || { echo "check_chat_prompt: build the extension dependencies first." >&2; exit 2; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/la_chat_prompt.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
if ! c++ -std=c++17 -I"$EXT/include" -I"$DEPS/include/llama" \
    "$EXT/src/RuntimeChatPrompt.cpp" "$EXT/tests/ChatPromptTest.cpp" \
    -L"$DEPS/lib" -Wl,-rpath,"$DEPS/lib" -lllama -o "$WORK/chat_prompt"; then
    echo "check_chat_prompt: the template rig could not compile." >&2
    exit 2
fi
LD_LIBRARY_PATH="$DEPS/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$WORK/chat_prompt"
