#!/usr/bin/env bash
# Prove the documented library boundary actually holds.
#
# docs/USAGE.md tells a consumer they can copy addons/local_agents/, delete the game, and keep a
# working local-agent toolkit. Nothing enforced that, and it had already rotted: two of the three
# "library showcase" demos referenced the LAAppExit autoload that the same doc says consumers must
# NOT register, so they were parse errors in a clean install.
#
# This builds that clean install for real and fails on any parse error. It deliberately omits the
# native binary, the game tree, and the optional zylann.voxel extension: the library has to PARSE
# without all three. Whether it can generate text is a different question, checked elsewhere.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-godot}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "check_library_only: staging a library-only project in $TMP"
mkdir -p "$TMP/addons/local_agents"

# Copy the addon WITHOUT the build tree. bin/ is excluded on purpose (and is a symlink in a
# worktree, which rsync -L would chase into gigabytes) — a consumer who has not built the extension
# yet must still get a clean scan.
rsync -a \
  --exclude 'gdextensions/localagents/thirdparty/' \
  --exclude 'gdextensions/localagents/build/' \
  --exclude 'gdextensions/localagents/build_native/' \
  --exclude 'gdextensions/localagents/bin/' \
  --exclude '.cache/' \
  "$ROOT/addons/local_agents/" "$TMP/addons/local_agents/"

# Delete everything the docs call game-only. What is left must stand on its own.
rm -rf "$TMP/addons/local_agents/game" \
       "$TMP/addons/local_agents/audio" \
       "$TMP/addons/local_agents/assets" \
       "$TMP/addons/local_agents/voices"

# A consumer's project.godot: the plugin, and the ONE core autoload. Deliberately no GameMode and no
# AppExit — registering those is exactly the mistake this gate is here to catch.
cat > "$TMP/project.godot" <<'PROJECT'
config_version=5

[application]
config/name="LibraryOnlyProbe"
config/features=PackedStringArray("4.7")

[autoload]
AgentManager="*res://addons/local_agents/agent_manager/AgentManager.gd"

[editor_plugins]
enabled=PackedStringArray("res://addons/local_agents/plugin.cfg")
PROJECT

LOG="$TMP/scan.log"
echo "check_library_only: scanning (no game, no zylann.voxel, no native binary)"
"$GODOT" --headless --editor --quit-after 400 --path "$TMP" > "$LOG" 2>&1 || true

# Unresolved class_name references (the LAAppExit failure mode) surface as parse errors, so this
# single grep covers both a missing script and a missing global identifier.
if grep -qiE 'Parse Error|SCRIPT ERROR|Failed to load script|Could not resolve class' "$LOG"; then
  echo "check_library_only: FAIL — the library does not parse without the game tree:"
  grep -inE 'Parse Error|SCRIPT ERROR|Failed to load script|Could not resolve class' "$LOG" \
    | sed 's/^/    /' | head -40
  echo
  echo "Fix by removing the game dependency, not by re-adding the file to the library set."
  exit 1
fi

echo "check_library_only: OK (library-only tree parses clean)"
